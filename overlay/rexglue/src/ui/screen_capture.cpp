/**
 * @file        ui/screen_capture.cpp
 * @brief       In-engine frame capture to PNG.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * The PNG encoder is written out longhand rather than calling a system imaging
 * API or vendoring one, for three reasons:
 *
 *  1. ImageIO (the obvious Apple choice) does NOT work reliably inside this
 *     process. Standalone it encodes fine; in-process CGImageDestinationFinalize
 *     never returns and leaves a zero-byte ".name.png-XXXXXX" temp file. This
 *     runtime installs its own SIGSEGV/SIGILL handler for guest MMIO traps and
 *     maps 4.5 GB of guest address space, so system frameworks that fault or
 *     call out to XPC are not safe to assume here. A capture tool that hangs the
 *     thing it is meant to observe is worse than useless.
 *  2. There is no vendored encoder to reuse -- upstream's trace_dump.cpp
 *     references stb_image_write, but that file is in no CMakeLists and does
 *     not compile.
 *  3. It has to work identically on macOS, the iOS simulator and a device.
 *
 * The deflate stream uses stored (uncompressed) blocks, which is valid zlib and
 * needs no compressor. Captures are a few MB instead of a few hundred KB; that
 * is irrelevant for a debugging artifact and buys total portability.
 */

#include <rex/ui/screen_capture.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/presenter.h>

REXCVAR_DEFINE_STRING(capture_dir, "", "Capture",
                      "Directory for in-engine PNG frame captures (empty = disabled)");
REXCVAR_DEFINE_INT32(capture_delay_ms, 5000, "Capture",
                     "Delay before the first in-engine capture");
REXCVAR_DEFINE_INT32(capture_interval_ms, 0, "Capture",
                     "Period between captures (0 = single capture)");
REXCVAR_DEFINE_INT32(capture_count, 1, "Capture", "Number of frames to capture");
REXCVAR_DEFINE_INT32(capture_retry_ms, 15000, "Capture",
                     "How long to keep polling for a guest frame per capture "
                     "(ConsumeGuestOutput is a mailbox; a single poll races the paint thread)");
REXCVAR_DEFINE_BOOL(capture_selftest, false, "Capture",
                    "Also write a synthetic test pattern, to verify the encoder independently "
                    "of whether the guest is presenting");

namespace rex {
namespace ui {

namespace {

std::thread g_capture_thread;
std::atomic<bool> g_capture_stop{false};

uint32_t Crc32(const uint8_t* data, size_t length, uint32_t crc = 0xFFFFFFFFu) {
  static uint32_t table[256];
  static bool table_ready = false;
  if (!table_ready) {
    for (uint32_t n = 0; n < 256; ++n) {
      uint32_t c = n;
      for (int k = 0; k < 8; ++k) {
        c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      }
      table[n] = c;
    }
    table_ready = true;
  }
  for (size_t i = 0; i < length; ++i) {
    crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  }
  return crc;
}

void PushBE32(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back(uint8_t(v >> 24));
  out.push_back(uint8_t(v >> 16));
  out.push_back(uint8_t(v >> 8));
  out.push_back(uint8_t(v));
}

void PushChunk(std::vector<uint8_t>& out, const char tag[4], const std::vector<uint8_t>& payload) {
  PushBE32(out, uint32_t(payload.size()));
  const size_t crc_begin = out.size();
  out.insert(out.end(), tag, tag + 4);
  out.insert(out.end(), payload.begin(), payload.end());
  const uint32_t crc = Crc32(out.data() + crc_begin, out.size() - crc_begin) ^ 0xFFFFFFFFu;
  PushBE32(out, crc);
}

}  // namespace

bool WriteRawImagePng(const std::filesystem::path& path, const RawImage& image) {
  if (!image.width || !image.height || image.data.empty()) {
    REXLOG_ERROR("Capture: empty image ({}x{}, {} bytes)", image.width, image.height,
                 image.data.size());
    return false;
  }
  const size_t src_stride = image.stride ? image.stride : size_t(image.width) * 4;

  // Raw PNG scanlines: one filter byte (0 = None) then RGB triplets. RawImage is
  // R8 G8 B8 X8, and the X byte is padding rather than alpha, so it is dropped
  // instead of being written as an alpha channel.
  std::vector<uint8_t> raw;
  raw.reserve((size_t(image.width) * 3 + 1) * image.height);
  for (uint32_t y = 0; y < image.height; ++y) {
    const size_t row_offset = size_t(y) * src_stride;
    if (row_offset >= image.data.size()) {
      break;  // last row is allowed to be short of the stride
    }
    raw.push_back(0);
    const uint8_t* src = image.data.data() + row_offset;
    const size_t available = image.data.size() - row_offset;
    for (uint32_t x = 0; x < image.width; ++x) {
      const size_t px = size_t(x) * 4;
      if (px + 2 >= available) {
        raw.insert(raw.end(), 3, 0);
        continue;
      }
      raw.push_back(src[px + 0]);
      raw.push_back(src[px + 1]);
      raw.push_back(src[px + 2]);
    }
  }

  // zlib stream around stored deflate blocks.
  std::vector<uint8_t> z;
  z.push_back(0x78);  // CMF: deflate, 32K window
  z.push_back(0x01);  // FLG: no dict, fastest; (0x78<<8|0x01) % 31 == 0
  constexpr size_t kMaxStored = 65535;
  for (size_t offset = 0; offset < raw.size(); offset += kMaxStored) {
    const size_t block = std::min(kMaxStored, raw.size() - offset);
    const bool last = (offset + block) >= raw.size();
    z.push_back(last ? 1 : 0);
    z.push_back(uint8_t(block & 0xFF));
    z.push_back(uint8_t(block >> 8));
    z.push_back(uint8_t(~block & 0xFF));
    z.push_back(uint8_t((~block >> 8) & 0xFF));
    z.insert(z.end(), raw.begin() + offset, raw.begin() + offset + block);
  }
  uint32_t a = 1, b = 0;
  for (uint8_t byte : raw) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  PushBE32(z, (b << 16) | a);

  std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  std::vector<uint8_t> ihdr;
  PushBE32(ihdr, image.width);
  PushBE32(ihdr, image.height);
  ihdr.push_back(8);  // bit depth
  ihdr.push_back(2);  // colour type 2 = truecolour RGB
  ihdr.push_back(0);  // deflate
  ihdr.push_back(0);  // adaptive filtering
  ihdr.push_back(0);  // no interlace
  PushChunk(png, "IHDR", ihdr);
  PushChunk(png, "IDAT", z);
  PushChunk(png, "IEND", {});

  std::FILE* f = std::fopen(path.string().c_str(), "wb");
  if (!f) {
    REXLOG_ERROR("Capture: cannot open {} for writing", path.string());
    return false;
  }
  const size_t written = std::fwrite(png.data(), 1, png.size(), f);
  std::fclose(f);
  if (written != png.size()) {
    REXLOG_ERROR("Capture: short write to {} ({}/{})", path.string(), written, png.size());
    return false;
  }
  REXLOG_INFO("Capture: wrote {} ({}x{}, {} bytes)", path.string(), image.width, image.height,
              png.size());
  return true;
}

void StartCaptureService(Presenter* presenter) {
  const std::string dir = REXCVAR_GET(capture_dir);
  if (dir.empty() || !presenter) {
    return;
  }
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);

  const int delay_ms = REXCVAR_GET(capture_delay_ms);
  const int interval_ms = REXCVAR_GET(capture_interval_ms);
  const int count = REXCVAR_GET(capture_count) > 0 ? REXCVAR_GET(capture_count) : 1;
  const bool selftest = REXCVAR_GET(capture_selftest);
  const int retry_window_ms = REXCVAR_GET(capture_retry_ms) > 0 ? REXCVAR_GET(capture_retry_ms) : 1;

  REXLOG_INFO("Capture: enabled -> {} (delay {} ms, interval {} ms, {} frame(s))", dir, delay_ms,
              interval_ms, count);

  g_capture_stop.store(false);
  g_capture_thread =
      std::thread([presenter, dir, delay_ms, interval_ms, count, selftest, retry_window_ms]() {
    const auto sleep_ms = [](int ms) {
      // Poll the stop flag so shutdown is not held up by a long interval.
      for (int slept = 0; slept < ms && !g_capture_stop.load(); slept += 50) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
      }
    };

    if (selftest) {
      // A gradient with a white diagonal: exercises every channel, and the
      // diagonal makes a wrong stride or a flipped row obvious at a glance.
      RawImage test;
      test.width = 256;
      test.height = 144;
      test.stride = size_t(test.width) * 4;
      test.data.resize(test.stride * test.height);
      for (uint32_t y = 0; y < test.height; ++y) {
        for (uint32_t x = 0; x < test.width; ++x) {
          uint8_t* px = test.data.data() + y * test.stride + x * 4;
          const bool diagonal = (x * test.height / test.width) == y;
          px[0] = diagonal ? 255 : uint8_t(x);
          px[1] = diagonal ? 255 : uint8_t(y * 255 / test.height);
          px[2] = diagonal ? 255 : uint8_t(255 - x);
          px[3] = 255;
        }
      }
      WriteRawImagePng(std::filesystem::path(dir) / "selftest.png", test);
    }

    sleep_ms(delay_ms);
    for (int i = 0; i < count && !g_capture_stop.load(); ++i) {
      // Presenter::ConsumeGuestOutput is a MAILBOX: it hands back the latest
      // image only if one has been refreshed since the last consume, and the
      // paint thread consumes every frame. A single poll from here almost always
      // loses that race. Retry hard for a window so we land on a frame the
      // moment the guest produces one -- which also means a capture request
      // issued before the first frame simply waits for it.
      RawImage image;
      bool got = false;
      for (int waited = 0; waited < retry_window_ms && !g_capture_stop.load(); waited += 5) {
        if (presenter->CaptureGuestOutput(image)) {
          got = true;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      if (got) {
        char name[64];
        std::snprintf(name, sizeof(name), "frame_%03d.png", i);
        WriteRawImagePng(std::filesystem::path(dir) / name, image);
      } else {
        REXLOG_WARN("Capture: no guest output after {} ms (frame {})", retry_window_ms, i);
      }
      if (i + 1 < count) {
        sleep_ms(interval_ms > 0 ? interval_ms : 1000);
      }
    }
    REXLOG_INFO("Capture: service finished");
  });
}

void StopCaptureService() {
  g_capture_stop.store(true);
  if (g_capture_thread.joinable()) {
    g_capture_thread.join();
  }
}

}  // namespace ui
}  // namespace rex

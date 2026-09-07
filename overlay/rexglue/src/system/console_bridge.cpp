/**
 * @file        system/console_bridge.cpp
 * @brief       Line-oriented TCP console for driving a running build.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * See rex/console_bridge.h for why this exists and why it is not shipped.
 */

#include <rex/console_bridge.h>

#include <rex/graphics/gpu_dispatch_stats.h>
#include <rex/platform.h>
#if REX_PLATFORM_IOS
#include <rex/ui/settings_uikit.h>
#endif

#include <atomic>
#include <cstring>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <rex/cvar.h>
#include <rex/perf/counter.h>
#include <rex/ui/vulkan/presenter_timings.h>
#include <rex/sampling_profiler.h>
#include <rex/logging.h>

// Defined in ObjC++ on iOS; absent on other platforms. A weak extern would
// need per-platform linker flags on Mach-O, so resolve it at runtime instead.
static const char* (*ThermalStateNameFn())() {
  static auto fn = reinterpret_cast<const char* (*)()>(
      dlsym(RTLD_DEFAULT, "RexThermalStateName"));
  return fn;
}

// Lives in the rexui library, which rexruntime does not link on macOS. Same
// treatment, same reason: a diagnostic must not reshape the link graph.
using PresenterTimingsFn = void (*)(uint64_t*, uint64_t*, uint64_t*, uint64_t*);
static PresenterTimingsFn PresenterTimings() {
  static auto fn =
      reinterpret_cast<PresenterTimingsFn>(dlsym(RTLD_DEFAULT, "RexGetPresenterTimings"));
  return fn;
}

// Likewise the WAIT_REG_MEM accounting, which lives in rexgraphics.
using WrmStatsFn = void (*)(uint64_t*, uint64_t*, uint64_t*);
using WrmWorstFn = void (*)(uint32_t*, uint32_t*, uint32_t*, uint32_t*);
using WrmVblankFn = void (*)(uint64_t*, uint64_t*, uint64_t*);
static WrmStatsFn WrmStats() {
  static auto fn = reinterpret_cast<WrmStatsFn>(dlsym(RTLD_DEFAULT, "RexGetWaitRegMemStats"));
  return fn;
}
static WrmWorstFn WrmWorst() {
  static auto fn = reinterpret_cast<WrmWorstFn>(dlsym(RTLD_DEFAULT, "RexGetWaitRegMemWorst"));
  return fn;
}
using GpuDispatchStatsFn = void (*)(uint64_t*, uint32_t);
static GpuDispatchStatsFn GpuDispatchStats() {
  static auto fn =
      reinterpret_cast<GpuDispatchStatsFn>(dlsym(RTLD_DEFAULT, "RexGetGpuDispatchStats"));
  return fn;
}
using GpuPassStatsFn = void (*)(uint64_t*, uint64_t*, uint64_t*);
static GpuPassStatsFn GpuPassStats() {
  static auto fn = reinterpret_cast<GpuPassStatsFn>(dlsym(RTLD_DEFAULT, "RexGetGpuPassStats"));
  return fn;
}
static WrmVblankFn WrmVblank() {
  static auto fn =
      reinterpret_cast<WrmVblankFn>(dlsym(RTLD_DEFAULT, "RexGetWaitRegMemVblankPhase"));
  return fn;
}

namespace rex {
namespace console {

namespace {

std::atomic<bool> g_running{false};
int g_listen_fd = -1;
StatsProvider g_stats;

std::string Trim(const std::string& s) {
  size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return {};
  size_t e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

std::string HelpText() {
  return
      "commands:\n"
      "  stat              live counters (fps, frame time, submit/present)\n"
      "  perf              every engine counter (draws, verts, stalls, caches)\n"
      "  prof start [hz]   begin sampling every thread's program counter\n"
      "  prof top [n]      where the time is: by image, then hottest sites\n"
      "  prof stop         stop sampling (counts are kept)\n"
      "  get <name>        read a cvar\n"
      "  set <name> <val>  write a cvar (takes effect per its lifecycle)\n"
      "  find <substr>     list cvars whose name or category matches\n"
      "  modified          list cvars that differ from their default\n"
      "  info <name>       type, category, default and description\n"
      "  reset <name>      restore a cvar's default\n"
#if REX_PLATFORM_IOS
      "  settings [close]  open (or close) the native settings page\n"
#endif
      "  help              this\n"
      "  quit              close this connection\n";
}

std::string DescribeFlag(const std::string& name) {
  const auto* info = cvar::GetFlagInfo(name);
  if (!info) {
    return "error: no such cvar: " + name + "\n";
  }
  std::ostringstream out;
  const char* lifecycle = "hot-reload";
  switch (info->lifecycle) {
    case cvar::Lifecycle::kInitOnly: lifecycle = "init-only"; break;
    case cvar::Lifecycle::kRequiresRestart: lifecycle = "requires-restart"; break;
    case cvar::Lifecycle::kHotReload: break;
  }
  out << info->name << " = " << cvar::GetFlagByName(name) << "\n"
      << "  default:   " << info->default_value << "\n"
      << "  category:  " << info->category << "\n"
      // Load-bearing for A/B work: only a hot-reload cvar can be flipped
      // mid-session and believed. device-ab.sh refuses the others.
      << "  lifecycle: " << lifecycle << "\n"
      << "  " << info->description << "\n";
  return out.str();
}

}  // namespace

std::string Execute(const std::string& raw) {
  const std::string line = Trim(raw);
  if (line.empty()) return {};

  std::istringstream in(line);
  std::string cmd;
  in >> cmd;

  if (cmd == "help" || cmd == "?") {
    return HelpText();
  }

  if (cmd == "stat") {
    BridgeStats s = g_stats ? g_stats() : BridgeStats{};
    std::ostringstream out;
    out.setf(std::ios::fixed);
    out.precision(2);
    out << "fps=" << s.fps << " frame_ms=" << s.frame_time_ms << " frames=" << s.frame_count
        << " submitted=" << s.submitted << " presented=" << s.presented;
    // A growing gap between these two is the signature of a stalled GPU, and it
    // is the first thing worth knowing from across the room.
    if (s.submitted > s.presented) {
      out << " (behind by " << (s.submitted - s.presented) << ")";
    }
    if (auto* thermal_name = ThermalStateNameFn()) {
      out << " thermal=" << thermal_name();
    }
    if (auto* timings = PresenterTimings()) {
      uint64_t aq = 0, pr = 0, aqmax = 0, prmax = 0;
      timings(&aq, &pr, &aqmax, &prmax);
      out << " | acquire=" << (aq / 1000.0) << "ms(max " << (aqmax / 1000.0) << ") present="
          << (pr / 1000.0) << "ms(max " << (prmax / 1000.0) << ")";
    }
    if (auto* wrm = WrmStats()) {
      uint64_t w = 0, tus = 0, mus = 0;
      wrm(&w, &tus, &mus);
      if (w) {
        out << " | wrm=" << w << "x " << (tus / 1000.0) << "ms(worst " << (mus / 1000.0) << ")";
        uint64_t vmean = 0, vmax = 0, vn = 0;
        if (auto* phase = WrmVblank()) phase(&vmean, &vmax, &vn);
        if (vn) {
          out << " after-vblank=" << (vmean / 1000.0) << "ms(max " << (vmax / 1000.0) << ")";
        }
        uint32_t addr = 0, ref = 0, op = 0, ismem = 0;
        if (auto* worst = WrmWorst()) worst(&addr, &ref, &op, &ismem);
        out << std::hex << " poll=" << addr << " ref=" << ref << std::dec << " op=" << op
            << (ismem ? " mem" : " reg");
      }
    }
    if (auto* passes_fn = GpuPassStats()) {
      uint64_t passes = 0, submissions = 0, swaps = 0;
      passes_fn(&passes, &submissions, &swaps);
      if (swaps) {
        out << " | passes/frame=" << (passes / swaps) << " cb/frame=" << (submissions / swaps);
        // The compute traffic M-061 found co-saturating the GPU with the draw
        // work: ~47 launches per frame standing still. Broken down by launch
        // site, because a total says only that it is large.
        if (auto* dispatch_fn = GpuDispatchStats()) {
          constexpr uint32_t kKinds = uint32_t(graphics::DispatchKind::kCount);
          uint64_t counts[kKinds] = {};
          dispatch_fn(counts, kKinds);
          uint64_t total = 0;
          for (uint64_t c : counts) total += c;
          out << " dispatch/frame=" << (total / swaps) << " (";
          bool first = true;
          for (uint32_t i = 0; i < kKinds; ++i) {
            if (!counts[i]) continue;
            if (!first) out << " ";
            first = false;
            out << graphics::DispatchKindName(graphics::DispatchKind(i)) << ":"
                << (counts[i] / swaps);
          }
          out << ")";
        }
      }
    }
    if (s.dbgnow_calls) {
      out << " | dbgnow=" << s.dbgnow_calls << " (slept " << s.dbgnow_sleeps << ")";
    }
    if (s.wait_cycles) {
      // The decomposition Fable asked for: how many submit->wait cycles a
      // displayed frame actually costs, and how the time splits between
      // waiting for the GPU and everything else.
      out << " | cycles/frame=" << s.wait_cycles << " wait=" << (s.wait_us / 1000.0)
          << "ms between=" << (s.between_us / 1000.0) << "ms";
    }
    out << "\n";
    return out.str();
  }

  if (cmd == "perf") {
    // Every counter, named, in one shot. Which of them are actually populated
    // is itself information: a counter reading zero during play means nothing
    // is feeding it, not that the work is free.
    std::ostringstream out;
    for (uint16_t i = 0; i < uint16_t(perf::CounterId::kCount); ++i) {
      const auto id = static_cast<perf::CounterId>(i);
      out << perf::CounterName(id) << "=" << perf::GetSnapshotCounter(id) << "\n";
    }
    return out.str();
  }

  if (cmd == "prof") {
    std::string sub;
    in >> sub;
    if (sub == "start") {
      uint32_t hz = 0;
      in >> hz;
      profiler::Start(hz ? hz : 500);
      return "sampling started\n";
    }
    if (sub == "stop") {
      profiler::Stop();
      return "sampling stopped\n";
    }
    if (sub == "reset") {
      profiler::Reset();
      return "cleared\n";
    }
    if (sub == "top" || sub.empty()) {
      size_t n = 0;
      in >> n;
      return profiler::Report(n ? n : 25);
    }
    return "usage: prof start [hz] | prof top [n] | prof stop | prof reset\n";
  }

#if REX_PLATFORM_IOS
  if (cmd == "settings") {
    // The native settings page, opened from across the room. Its real value is
    // the sim gate: no synthetic touch reaches UIKit on this runtime, so a
    // console-driven open is the only way to photograph the page without a
    // human thumb.
    std::string sub;
    in >> sub;
    if (sub == "close") {
      ui::DismissSettings();
      return "settings closed\n";
    }
    ui::PresentSettings();
    return "settings opened\n";
  }
#endif  // REX_PLATFORM_IOS

  if (cmd == "get") {
    std::string name;
    in >> name;
    if (name.empty()) return "usage: get <name>\n";
    if (!cvar::GetFlagInfo(name)) return "error: no such cvar: " + name + "\n";
    return name + " = " + cvar::GetFlagByName(name) + "\n";
  }

  if (cmd == "set") {
    std::string name, value;
    in >> name;
    std::getline(in, value);
    value = Trim(value);
    if (name.empty() || value.empty()) return "usage: set <name> <value>\n";
    const auto* set_info = cvar::GetFlagInfo(name);
    if (!set_info) return "error: no such cvar: " + name + "\n";
    // The registry's own lifecycle check is dead code: it only bites after
    // cvar::FinalizeInit(), which nothing in this SDK or the game ever calls.
    // So init-only means nothing at runtime -- including for
    // gpu_interrupt_on_wait_reg_mem, which kills a healthy game within a
    // millisecond (M-060). The console is the only path a human flips a cvar
    // from, so it is the right place to enforce it.
    if (set_info->lifecycle == cvar::Lifecycle::kInitOnly) {
      return "error: " + name +
             " is init-only -- set it in ge.toml and relaunch.\n"
             "       (flipping it on a running game is unsupported and may be fatal;\n"
             "        `info " + name + "` says why)\n";
    }
    if (!cvar::SetFlagByName(name, value)) {
      return "error: rejected (out of range, or not settable at runtime)\n";
    }
    REXLOG_INFO("console: set {} = {}", name, value);
    std::string reply = name + " = " + cvar::GetFlagByName(name) + "\n";
    if (set_info->lifecycle == cvar::Lifecycle::kRequiresRestart) {
      // Silently accepting this is how a live A/B of a translation-time flag
      // comes back "no difference" and gets believed (Fable, round 7).
      reply += "       note: takes effect on relaunch -- measuring it live is invalid\n";
    }
    return reply;
  }

  if (cmd == "info") {
    std::string name;
    in >> name;
    if (name.empty()) return "usage: info <name>\n";
    return DescribeFlag(name);
  }

  if (cmd == "reset") {
    std::string name;
    in >> name;
    if (name.empty()) return "usage: reset <name>\n";
    if (!cvar::GetFlagInfo(name)) return "error: no such cvar: " + name + "\n";
    cvar::ResetToDefault(name);
    return name + " = " + cvar::GetFlagByName(name) + " (default)\n";
  }

  if (cmd == "find") {
    std::string needle;
    in >> needle;
    std::ostringstream out;
    size_t hits = 0;
    for (const auto& entry : cvar::GetRegistry()) {
      if (!needle.empty() && entry.name.find(needle) == std::string::npos &&
          entry.category.find(needle) == std::string::npos) {
        continue;
      }
      out << entry.name << " = " << cvar::GetFlagByName(entry.name) << "\n";
      ++hits;
    }
    if (!hits) return "no match\n";
    return out.str();
  }

  if (cmd == "modified") {
    std::ostringstream out;
    for (const auto& name : cvar::ListModifiedFlags()) {
      out << name << " = " << cvar::GetFlagByName(name) << "\n";
    }
    std::string s = out.str();
    return s.empty() ? "nothing differs from default\n" : s;
  }

  return "error: unknown command '" + cmd + "' (try help)\n";
}

namespace {

void ServeClient(int fd) {
  const std::string banner =
      "GoldenEye console. 'help' for commands.\n";
  ::send(fd, banner.data(), banner.size(), 0);

  std::string pending;
  char buf[1024];
  while (g_running.load(std::memory_order_relaxed)) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    pending.append(buf, size_t(n));

    size_t nl;
    while ((nl = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, nl);
      pending.erase(0, nl + 1);
      if (Trim(line) == "quit") {
        const char* bye = "bye\n";
        ::send(fd, bye, 4, 0);
        ::close(fd);
        return;
      }
      std::string reply = Execute(line);
      if (!reply.empty()) {
        ::send(fd, reply.data(), reply.size(), 0);
      }
    }
  }
  ::close(fd);
}

void AcceptLoop() {
  while (g_running.load(std::memory_order_relaxed)) {
    sockaddr_in peer{};
    socklen_t peer_len = sizeof(peer);
    int fd = ::accept(g_listen_fd, reinterpret_cast<sockaddr*>(&peer), &peer_len);
    if (fd < 0) {
      if (errno == EINTR) continue;
      break;  // listener closed, or the socket is gone
    }
    char who[INET_ADDRSTRLEN] = {};
    ::inet_ntop(AF_INET, &peer.sin_addr, who, sizeof(who));
    REXLOG_INFO("console: client connected from {}", who);
    std::thread(ServeClient, fd).detach();
  }
}

}  // namespace

void Start(uint16_t port, StatsProvider stats_provider) {
  if (g_running.exchange(true)) {
    return;
  }
  g_stats = std::move(stats_provider);

  g_listen_fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (g_listen_fd < 0) {
    REXLOG_ERROR("console: socket() failed: {}", std::strerror(errno));
    g_running = false;
    return;
  }
  int one = 1;
  ::setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons(port);
  if (::bind(g_listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    REXLOG_ERROR("console: bind({}) failed: {}", port, std::strerror(errno));
    ::close(g_listen_fd);
    g_listen_fd = -1;
    g_running = false;
    return;
  }
  if (::listen(g_listen_fd, 4) != 0) {
    REXLOG_ERROR("console: listen() failed: {}", std::strerror(errno));
    ::close(g_listen_fd);
    g_listen_fd = -1;
    g_running = false;
    return;
  }

  std::thread(AcceptLoop).detach();
  REXLOG_INFO("console: listening on port {}", port);
}

void Stop() {
  if (!g_running.exchange(false)) {
    return;
  }
  if (g_listen_fd >= 0) {
    ::shutdown(g_listen_fd, SHUT_RDWR);
    ::close(g_listen_fd);
    g_listen_fd = -1;
  }
}

}  // namespace console
}  // namespace rex

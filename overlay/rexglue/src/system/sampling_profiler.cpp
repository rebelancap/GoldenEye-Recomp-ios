/**
 * @file        system/sampling_profiler.cpp
 * @brief       In-process sampling profiler, readable over the console.
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 * See rex/sampling_profiler.h for why this exists.
 */

#include <rex/sampling_profiler.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <cstdio>

#include <rex/logging.h>
#include <rex/ppc/context.h>

namespace rex {
namespace profiler {

namespace {

struct HostRange {
  uintptr_t host;   // host address of the recompiled function
  uintptr_t end;    // one past its last byte, from the next function's start
  uint32_t guest;   // the guest address it came from
};

// A recompiled function is big but not unbounded. Anything further than this
// past a known start is somewhere else entirely -- padding, a runtime helper,
// a stub -- and must not be attributed to that function.
constexpr uintptr_t kMaxFunctionExtent = 256 * 1024;

// Per thread, because a whole-process histogram is meaningless here: most
// threads in this process are idle pools, and averaging them in buries the two
// or three that actually do the frame's work. The first version of this
// reported 95.8% "libsystem_kernel" -- true, useless, and mostly the console's
// own accept() call (M-047).
struct ThreadStats {
  std::string name;
  uint64_t samples = 0;
  uint64_t running = 0;  // samples NOT parked in a kernel wait
  std::unordered_map<std::string, uint64_t> images;
  std::unordered_map<uintptr_t, uint64_t> sites;
  // Where the thread waits, keyed by the *caller* of the syscall rather than
  // the syscall itself. "__psynch_cvwait" says nothing; the return address says
  // which wait it is, which is the whole question when a frame is bounded by a
  // dependency chain rather than by work.
  std::unordered_map<uintptr_t, uint64_t> wait_sites;
};

std::atomic<bool> g_running{false};
std::thread g_thread;
std::mutex g_mutex;                                  // guards the tables below
std::unordered_map<uint64_t, ThreadStats> g_threads;  // stable thread id -> stats
std::unordered_map<uintptr_t, uint64_t> g_site_hits;  // resolved site -> samples
std::unordered_map<std::string, uint64_t> g_image_hits;
uint64_t g_total_samples = 0;
std::vector<HostRange> g_guest_funcs;  // sorted by host address
uintptr_t g_guest_lo = 0, g_guest_hi = 0;
const ::PPCFuncMapping* g_mappings = nullptr;

// Build the host->guest reverse index once. The generated table is guest-sorted
// and terminated by a zero guest address; we need it ordered by host address to
// answer "which function contains this PC".
void BuildGuestIndex() {
  if (!g_guest_funcs.empty() || !g_mappings) return;
  for (size_t i = 0; g_mappings[i].guest != 0; ++i) {
    auto* host = g_mappings[i].host;
    if (!host) continue;
    g_guest_funcs.push_back({reinterpret_cast<uintptr_t>(host), 0,
                             static_cast<uint32_t>(g_mappings[i].guest)});
  }
  std::sort(g_guest_funcs.begin(), g_guest_funcs.end(),
            [](const HostRange& a, const HostRange& b) { return a.host < b.host; });
  // Give every function an end, taken from the next one's start. Without this
  // the table's final entry swallows every unmapped address in the image and
  // shows up as a phantom hotspot in every thread -- which is exactly what the
  // first per-thread profile reported (M-047).
  for (size_t i = 0; i + 1 < g_guest_funcs.size(); ++i) {
    const uintptr_t gap = g_guest_funcs[i + 1].host - g_guest_funcs[i].host;
    g_guest_funcs[i].end = g_guest_funcs[i].host + std::min(gap, kMaxFunctionExtent);
  }
  if (!g_guest_funcs.empty()) {
    g_guest_funcs.back().end = g_guest_funcs.back().host + kMaxFunctionExtent;
    g_guest_lo = g_guest_funcs.front().host;
    g_guest_hi = g_guest_funcs.back().end;
  }
  REXLOG_INFO("profiler: indexed {} recompiled functions ({:#x}-{:#x})", g_guest_funcs.size(),
              g_guest_lo, g_guest_hi);
}

// The guest function containing `pc`, or 0.
uint32_t GuestFunctionFor(uintptr_t pc) {
  if (pc < g_guest_lo || pc >= g_guest_hi || g_guest_funcs.empty()) return 0;
  // Last entry whose host address is <= pc.
  auto it = std::upper_bound(g_guest_funcs.begin(), g_guest_funcs.end(), pc,
                             [](uintptr_t v, const HostRange& r) { return v < r.host; });
  if (it == g_guest_funcs.begin()) return 0;
  --it;
  // Inside a *known* extent, not merely after some function's start.
  return pc < it->end ? it->guest : 0;
}

std::string ImageNameFor(uintptr_t pc) {
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(pc), &info) && info.dli_fname) {
    std::string path = info.dli_fname;
    auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
  }
  return "<unknown>";
}

std::string DescribeAddress(uintptr_t pc) {
  if (uint32_t guest = GuestFunctionFor(pc)) {
    char buf[32];
    snprintf(buf, sizeof(buf), "sub_%08x (recompiled)", guest);
    return buf;
  }
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(pc), &info) && info.dli_sname) {
    return std::string(info.dli_sname) + "  [" + ImageNameFor(pc) + "]";
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)pc);
  return std::string(buf) + "  [" + ImageNameFor(pc) + "]";
}

void SampleOnce() {
  thread_act_array_t threads = nullptr;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
    return;
  }
  const thread_t self = mach_thread_self();

  std::lock_guard<std::mutex> lock(g_mutex);
  for (mach_msg_type_number_t i = 0; i < count; ++i) {
    if (threads[i] == self) continue;  // never profile the sampler

    arm_thread_state64_t state{};
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(threads[i], ARM_THREAD_STATE64,
                         reinterpret_cast<thread_state_t>(&state), &state_count) != KERN_SUCCESS) {
      continue;
    }
    // Threads parked in the kernel still report a PC; that is wanted -- time
    // asleep in a wait is exactly as interesting as time spent computing.
    const uintptr_t pc = uintptr_t(arm_thread_state64_get_pc(state));
    if (!pc) continue;
    // The link register holds the return address: for a thread parked in a
    // syscall that is the code that decided to wait.
    const uintptr_t lr = uintptr_t(arm_thread_state64_get_lr(state));

    // Identify the thread stably and by name. Mach ports get recycled, so key
    // on the pthread's unique id; the name is what makes the report readable
    // ("GPU Commands", "Main XThread").
    uint64_t tid = 0;
    std::string tname;
    if (pthread_t p = pthread_from_mach_thread_np(threads[i])) {
      pthread_threadid_np(p, &tid);
      char buf[64] = {};
      if (pthread_getname_np(p, buf, sizeof(buf)) == 0 && buf[0]) {
        tname = buf;
      }
    }
    if (!tid) tid = uint64_t(threads[i]);

    const std::string image =
        GuestFunctionFor(pc) ? std::string("recompiled guest code") : ImageNameFor(pc);

    ++g_total_samples;
    ++g_site_hits[pc];
    ++g_image_hits[image];

    auto& ts = g_threads[tid];
    if (ts.name.empty() && !tname.empty()) ts.name = tname;
    ++ts.samples;
    // "Running" means not parked in a syscall. A thread at 5% running is idle
    // no matter how many samples it collected.
    if (image != "libsystem_kernel.dylib") {
      ++ts.running;
      ++ts.sites[pc];
      ++ts.images[image];
    } else if (lr) {
      ++ts.wait_sites[lr];
    }
  }
  mach_port_deallocate(mach_task_self(), self);
  vm_deallocate(mach_task_self(), vm_address_t(threads), count * sizeof(thread_t));
}

void SamplerMain(uint32_t hz) {
  const auto period = std::chrono::microseconds(1000000 / std::max(1u, hz));
  while (g_running.load(std::memory_order_relaxed)) {
    SampleOnce();
    std::this_thread::sleep_for(period);
  }
}

}  // namespace

void SetGuestFunctionTable(const ::PPCFuncMapping* mappings) {
  g_mappings = mappings;
}

void Start(uint32_t hz) {
  Stop();
  BuildGuestIndex();
  Reset();
  hz = std::clamp(hz, 20u, 1000u);
  g_running.store(true, std::memory_order_relaxed);
  g_thread = std::thread(SamplerMain, hz);
  REXLOG_INFO("profiler: sampling at {} Hz", hz);
}

void Stop() {
  if (!g_running.exchange(false)) return;
  if (g_thread.joinable()) g_thread.join();
  REXLOG_INFO("profiler: stopped");
}

bool IsRunning() {
  return g_running.load(std::memory_order_relaxed);
}

void Reset() {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_site_hits.clear();
  g_image_hits.clear();
  g_threads.clear();
  g_total_samples = 0;
}

std::string Report(size_t max_rows) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_total_samples) {
    return "no samples yet (prof start, wait a few seconds, prof top)\n";
  }

  std::ostringstream out;
  out.setf(std::ios::fixed);
  out.precision(1);
  out << "samples=" << g_total_samples << (g_running ? " (sampling)" : " (stopped)") << "\n";

  // Busiest threads first, measured by time actually running rather than by
  // sample count -- an idle thread accrues samples just as fast as a busy one.
  std::vector<const ThreadStats*> threads;
  threads.reserve(g_threads.size());
  for (const auto& [tid, ts] : g_threads) threads.push_back(&ts);
  std::sort(threads.begin(), threads.end(),
            [](const ThreadStats* a, const ThreadStats* b) { return a->running > b->running; });

  out << "\nthreads by time running (not parked in a syscall):\n";
  for (const ThreadStats* ts : threads) {
    if (!ts->running) continue;
    const double busy = 100.0 * double(ts->running) / double(ts->samples ? ts->samples : 1);
    out << "  " << (ts->name.empty() ? std::string("<unnamed>") : ts->name) << ": " << busy
        << "% busy (" << ts->running << " running / " << ts->samples << " samples)\n";

    std::vector<std::pair<std::string, uint64_t>> imgs(ts->images.begin(), ts->images.end());
    std::sort(imgs.begin(), imgs.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });
    for (size_t i = 0; i < imgs.size() && i < 4; ++i) {
      out << "      " << (100.0 * double(imgs[i].second) / double(ts->running)) << "%  "
          << imgs[i].first << "\n";
    }

    std::vector<std::pair<uintptr_t, uint64_t>> sites(ts->sites.begin(), ts->sites.end());
    std::sort(sites.begin(), sites.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });
    for (size_t i = 0; i < sites.size() && i < max_rows / 4 + 2; ++i) {
      out << "        " << (100.0 * double(sites[i].second) / double(ts->running)) << "%  "
          << DescribeAddress(sites[i].first) << "\n";
    }

    const uint64_t waiting = ts->samples - ts->running;
    if (waiting) {
      out << "      waiting " << (100.0 * double(waiting) / double(ts->samples)) << "% of the time, on:\n";
      std::vector<std::pair<uintptr_t, uint64_t>> waits(ts->wait_sites.begin(),
                                                        ts->wait_sites.end());
      std::sort(waits.begin(), waits.end(),
                [](const auto& a, const auto& b) { return a.second > b.second; });
      for (size_t i = 0; i < waits.size() && i < 5; ++i) {
        out << "        " << (100.0 * double(waits[i].second) / double(waiting)) << "%  "
            << DescribeAddress(waits[i].first) << "\n";
      }
    }
  }
  return out.str();
}

}  // namespace profiler
}  // namespace rex

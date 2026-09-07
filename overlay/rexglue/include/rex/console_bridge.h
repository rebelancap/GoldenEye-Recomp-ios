/**
 * @file        rex/console_bridge.h
 * @brief       Line-oriented TCP console for driving a running build (port 8773).
 *
 * Added by the GoldenEye-Recomp-ios overlay -- not upstream.
 *
 * A phone has no terminal, and the interesting questions ("what is the frame
 * time right now", "what happens if render scale drops") only have answers
 * while someone is actually playing. This exposes the cvar registry and a few
 * live counters over a private network so a session can be inspected and steered from
 * a laptop without interrupting the person holding the device.
 *
 * Port 8773 is this project's allocation in the family's range (8765-8769
 * HarbourMasters, 8771 realrtcw, 8772 dhewm3).
 *
 * NOT COMPILED INTO PUBLIC BUILDS -- see REX_CONSOLE_BRIDGE in CMakeLists.txt.
 * It binds all interfaces and takes unauthenticated commands, which is fine on
 * a private network and unacceptable anywhere else.
 */

#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace rex {
namespace console {

/// Live counters the console reports. Filled by whoever owns the frame loop.
struct BridgeStats {
  double fps = 0.0;
  double frame_time_ms = 0.0;
  uint64_t frame_count = 0;
  /// Guest-side submit/present counters, for spotting a stalled GPU from afar.
  uint64_t submitted = 0;
  uint64_t presented = 0;
  /// Frame-phase decomposition: submit->wait cycles per displayed frame, and
  /// how the frame splits between waiting on the GPU and everything else.
  uint32_t wait_cycles = 0;
  uint64_t wait_us = 0;
  uint64_t between_us = 0;
  /// How often the guest polled its frame-timing hook since the last read, and
  /// how many of those slept instead of spinning. The poll rate is the whole
  /// cost of that hook, and after M-057 it is most of the port's CPU.
  uint64_t dbgnow_calls = 0;
  uint64_t dbgnow_sleeps = 0;
};

using StatsProvider = std::function<BridgeStats()>;

/// Start listening. Safe to call once; a second call is a no-op. Never blocks:
/// the accept loop and each client run on their own detached threads.
void Start(uint16_t port, StatsProvider stats_provider);

/// Stop listening and drop clients. Safe to call if Start never ran.
void Stop();

/// Feed the console a command as if it arrived over the socket, returning the
/// reply. Exposed for tests and for the in-game overlay to share one grammar.
std::string Execute(const std::string& line);

}  // namespace console
}  // namespace rex

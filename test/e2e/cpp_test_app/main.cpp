/**
 * flutter-skill C++ e2e test app.
 *
 * A headless bridge server used by test-cpp.mjs to verify that the C++ SDK
 * integrates correctly with the flutter-skill MCP protocol.
 *
 * Build (from this directory):
 *   cmake -B build -DCPP_SDK_DIR=<repo>/sdks/cpp && cmake --build build
 *   ./build/cpp_test_app [port]
 */

#include <flutter_skill/bridge.h>

#include <atomic>
#include <csignal>
#include <cstdio>
#include <thread>

static std::atomic<bool> g_stop{false};

static void on_signal(int) { g_stop = true; }

int main(int argc, char* argv[]) {
    flutter_skill::BridgeOptions opts;
    opts.app_name = "cpp-e2e-test-app";
    if (argc > 1) opts.port = std::atoi(argv[1]);

    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    flutter_skill::FlutterSkillBridge bridge(opts);
    try {
        bridge.start();
        // Print a marker so the test script knows the bridge is ready.
        fprintf(stdout, "[cpp_test_app] Bridge ready on port %d\n", opts.port);
        fflush(stdout);

        while (!g_stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        bridge.stop();
    } catch (const std::exception& e) {
        fprintf(stderr, "[cpp_test_app] Error: %s\n", e.what());
        return 1;
    }
    return 0;
}

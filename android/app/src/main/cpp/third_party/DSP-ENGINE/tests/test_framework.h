/**
 * Minimal unit-test framework.
 * Tests are REGISTERED in static initializers but only RUN from main()
 * (avoids Windows loader-lock deadlock when tests call into a shared DLL).
 */
#ifndef DSP_TEST_FRAMEWORK_H
#define DSP_TEST_FRAMEWORK_H

#include <cstdio>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>
#include <functional>

namespace dsp_test {

struct TestCase {
    const char* name;
    void (*fn)();
};

inline std::vector<TestCase>& registry() {
    static std::vector<TestCase> r;
    return r;
}

struct TestResult {
    const char* name;
    bool passed;
    std::string message;
};

inline std::vector<TestResult>& results() {
    static std::vector<TestResult> r;
    return r;
}

inline int& failed() {
    static int f = 0;
    return f;
}

/** Register only — do not execute the test body here. */
#define TEST(name) \
    static void test_##name(); \
    struct TestReg_##name { \
        TestReg_##name() { \
            dsp_test::registry().push_back({#name, &test_##name}); \
        } \
    }; \
    static TestReg_##name reg_##name; \
    static void test_##name()

#define EXPECT_TRUE(cond) \
    do { \
        if (!(cond)) throw std::string("EXPECT_TRUE failed: " #cond); \
    } while (0)

#define EXPECT_FALSE(cond) EXPECT_TRUE(!(cond))

#define EXPECT_EQ(a, b) \
    do { \
        if ((a) != (b)) { \
            char buf[256]; \
            std::snprintf(buf, sizeof(buf), "EXPECT_EQ failed: %s != %s", #a, #b); \
            throw std::string(buf); \
        } \
    } while (0)

#define EXPECT_NEAR(a, b, tol) \
    do { \
        double _a = (double)(a), _b = (double)(b); \
        if (std::fabs(_a - _b) > (tol)) { \
            char buf[256]; \
            std::snprintf(buf, sizeof(buf), "EXPECT_NEAR failed: %g vs %g (tol %g)", _a, _b, (double)(tol)); \
            throw std::string(buf); \
        } \
    } while (0)

#define EXPECT_GT(a, b) EXPECT_TRUE((a) > (b))
#define EXPECT_LT(a, b) EXPECT_TRUE((a) < (b))
#define EXPECT_GE(a, b) EXPECT_TRUE((a) >= (b))
#define EXPECT_LE(a, b) EXPECT_TRUE((a) <= (b))

inline int run_all() {
    results().clear();
    failed() = 0;
    printf("\n=== DSP ENGINE unit tests ===\n");
    for (const auto& tc : registry()) {
        try {
            tc.fn();
            results().push_back({tc.name, true, ""});
            printf("[ PASS ] %s\n", tc.name);
        } catch (const std::string& msg) {
            failed()++;
            results().push_back({tc.name, false, msg});
            printf("[ FAIL ] %s — %s\n", tc.name, msg.c_str());
        } catch (...) {
            failed()++;
            results().push_back({tc.name, false, "unknown exception"});
            printf("[ FAIL ] %s — unknown exception\n", tc.name);
        }
    }
    printf("------------------------------\n");
    printf("%d tests, %d failed\n\n",
           static_cast<int>(registry().size()), failed());
    return failed() == 0 ? 0 : 1;
}

} // namespace dsp_test

#endif // DSP_TEST_FRAMEWORK_H

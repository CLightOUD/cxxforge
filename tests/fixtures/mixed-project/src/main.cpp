#include <answer.hpp>

extern "C" int c_value(void);
extern "C" int cpp_value(void);

int main() {
    return c_value() + cpp_value() == expected_answer ? 0 : 1;
}

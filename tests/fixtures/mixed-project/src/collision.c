#include <winsock2.h>

int c_value(void) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return -1;
    WSACleanup();
    return 20;
}

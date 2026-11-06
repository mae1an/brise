// Minimal AppleSMC client. Struct layout matches the kernel's SMCKeyData_t.
#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } smc_keyinfo_t;

typedef struct {
    uint32_t      key;
    smc_vers_t    vers;
    smc_plimit_t  pLimitData;
    smc_keyinfo_t keyInfo;
    char          result;
    char          status;
    char          data8;
    uint32_t      data32;
    uint8_t       bytes[32];
} smc_keydata_t;

static io_connect_t conn = 0;

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |  (uint32_t)(uint8_t)s[3];
}

static void key_to_str(uint32_t k, char out[5]) {
    out[0] = (char)(k >> 24); out[1] = (char)(k >> 16);
    out[2] = (char)(k >> 8);  out[3] = (char)k; out[4] = 0;
}

static kern_return_t smc_call(smc_keydata_t *in, smc_keydata_t *out) {
    size_t outSize = sizeof(smc_keydata_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(smc_keydata_t), out, &outSize);
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (r != KERN_SUCCESS) { conn = 0; return -2; }
    return 0;
}

void smc_close(void) {
    if (conn) { IOServiceClose(conn); conn = 0; }
}

static int smc_keyinfo(uint32_t key, smc_keyinfo_t *ki) {
    smc_keydata_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *ki = out.keyInfo;
    return 0;
}

int smc_read(const char *key, char type[5], uint32_t *size, uint8_t bytes[32]) {
    if (smc_open() != 0 || strlen(key) != 4) return -1;
    uint32_t k = str_to_key(key);
    smc_keyinfo_t ki;
    if (smc_keyinfo(k, &ki) != 0) return -2;

    smc_keydata_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = k;
    in.keyInfo.dataSize = ki.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -3;

    key_to_str(ki.dataType, type);
    *size = ki.dataSize > 32 ? 32 : ki.dataSize;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    if (smc_open() != 0 || strlen(key) != 4 || size > 32) return -1;
    uint32_t k = str_to_key(key);
    smc_keyinfo_t ki;
    if (smc_keyinfo(k, &ki) != 0) return -2;
    if (ki.dataSize != size) return -4;

    smc_keydata_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = k;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    kern_return_t r = smc_call(&in, &out);
    if (r != KERN_SUCCESS) return (int)r;
    if (out.result != 0) return -3;
    return 0;
}

uint32_t smc_key_count(void) {
    char type[5]; uint32_t size; uint8_t b[32];
    if (smc_read("#KEY", type, &size, b) != 0) return 0;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

int smc_key_at(uint32_t index, char key[5]) {
    if (smc_open() != 0) return -1;
    smc_keydata_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    key_to_str(out.key, key);
    return 0;
}

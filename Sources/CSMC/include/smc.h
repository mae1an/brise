#ifndef BRISE_SMC_H
#define BRISE_SMC_H

#include <stdint.h>

/// Opens the connection to the AppleSMC driver. Returns 0 on success.
int smc_open(void);
void smc_close(void);

/// Reads a 4-char key. Fills `type` (4 chars + NUL), `size` and up to 32 `bytes`.
/// Returns 0 on success, negative on error (e.g. key not found).
int smc_read(const char *key, char type[5], uint32_t *size, uint8_t bytes[32]);

/// Writes raw bytes to a key. Requires root. Returns 0 on success.
int smc_write(const char *key, const uint8_t *bytes, uint32_t size);

/// Total number of keys exposed by the SMC.
uint32_t smc_key_count(void);

/// Key name at a given index (0 ..< smc_key_count()). Returns 0 on success.
int smc_key_at(uint32_t index, char key[5]);

#endif

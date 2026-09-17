/*
 * maic_stress: CPU load that VERIFIES its own results.
 *
 * Plain busy loops load a core but cannot detect the failure mode that matters when
 * undervolting/overclocking: silently wrong arithmetic before an outright crash. Each worker
 * repeatedly runs a fixed, deterministic mix of integer multiply/xor/rotate, FNV-1a hashing
 * over a scratch buffer, and a small prime sieve, and compares every round against the
 * golden value computed once at start-up on the same thread. Any mismatch is reported and the
 * process exits non-zero, so a soak script can stop and revert immediately.
 *
 * usage: maic_stress [threads=4] [seconds=60]
 * exit:  0 = all rounds matched, 2 = mismatch (instability), 1 = usage/setup error
 * Build: gcc -O2 -static -pthread -o maic_stress maic_stress.c   (aarch64)
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUF_SZ (1 << 20)		/* 1 MiB per thread: exercises cache + memory bus too */
#define SIEVE_N 200000

static volatile int g_fail;
static int g_seconds = 60;

static uint64_t round_once(uint8_t *buf, uint8_t *sieve)
{
	uint64_t x = 0x9e3779b97f4a7c15ULL, h = 1469598103934665603ULL;
	size_t i, j;
	unsigned primes = 0;

	for (i = 0; i < BUF_SZ; i++) {
		x ^= x << 13; x ^= x >> 7; x ^= x << 17;
		buf[i] = (uint8_t)(x >> 29);
	}
	for (i = 0; i < BUF_SZ; i++) {
		h ^= buf[i];
		h *= 1099511628211ULL;
	}
	memset(sieve, 1, SIEVE_N);
	sieve[0] = sieve[1] = 0;
	for (i = 2; i * i < SIEVE_N; i++)
		if (sieve[i])
			for (j = i * i; j < SIEVE_N; j += i)
				sieve[j] = 0;
	for (i = 0; i < SIEVE_N; i++)
		primes += sieve[i];
	for (i = 0; i < 4096; i++)
		h = (h * 6364136223846793005ULL + primes) ^ (h >> 31) ^ (i * 0x100000001b3ULL);
	return h;
}

static void *worker(void *arg)
{
	long id = (long)arg;
	uint8_t *buf = malloc(BUF_SZ), *sieve = malloc(SIEVE_N);
	uint64_t golden, got, rounds = 0;
	time_t end;

	if (!buf || !sieve) {
		fprintf(stderr, "thread %ld: malloc failed\n", id);
		g_fail = 1;
		return NULL;
	}
	golden = round_once(buf, sieve);
	end = time(NULL) + g_seconds;
	while (!g_fail && time(NULL) < end) {
		got = round_once(buf, sieve);
		rounds++;
		if (got != golden) {
			fprintf(stderr, "MISMATCH thread=%ld round=%llu golden=%016llx got=%016llx\n",
				id, (unsigned long long)rounds, (unsigned long long)golden,
				(unsigned long long)got);
			g_fail = 2;
		}
	}
	printf("thread %ld: %llu rounds ok=%d\n", id, (unsigned long long)rounds, g_fail == 0);
	free(buf);
	free(sieve);
	return NULL;
}

int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 4;
	long i;
	pthread_t th[64];

	if (argc > 2)
		g_seconds = atoi(argv[2]);
	if (n < 1 || n > 64 || g_seconds < 1) {
		fprintf(stderr, "usage: %s [threads 1-64] [seconds]\n", argv[0]);
		return 1;
	}
	for (i = 0; i < n; i++)
		pthread_create(&th[i], NULL, worker, (void *)i);
	for (i = 0; i < n; i++)
		pthread_join(th[i], NULL);
	printf("RESULT %s\n", g_fail ? "FAIL" : "PASS");
	return g_fail;
}

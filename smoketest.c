/*
 * Minimal NOE UMD smoke test: open the NPU through libnoe and read back the
 * hardware topology. No compiled model required - this exercises the
 * userspace -> /dev/aipu -> aipu.ko path end to end.
 */
#include <stdint.h>
#include <stdio.h>
#include "npu/cix_noe_standard_api.h"

static context_handler_t *ctx;

static int check(const char *what, noe_status_t r)
{
	printf("%-28s -> %d", what, r);
	if (r != NOE_STATUS_SUCCESS) {
		const char *msg = NULL;
		if (ctx && noe_get_error_message(ctx, r, &msg) == NOE_STATUS_SUCCESS && msg)
			printf("  (%s)", msg);
		printf("  FAIL\n");
		return 0;
	}
	printf("\n");
	return 1;
}

int main(void)
{
	if (!check("noe_init_context", noe_init_context(&ctx)))
		return 1;

	char target[256] = { 0 };
	if (check("noe_get_target", noe_get_target(ctx, target)))
		printf("    NPU arch: %s\n", target);

	uint32_t parts = 0;
	if (check("noe_get_partition_count", noe_get_partition_count(ctx, &parts))) {
		printf("    partitions: %u\n", parts);
		for (uint32_t p = 0; p < parts; p++) {
			uint32_t clusters = 0;
			noe_get_cluster_count(ctx, p, &clusters);
			printf("    partition %u: %u cluster(s)\n", p, clusters);
			for (uint32_t c = 0; c < clusters; c++) {
				uint32_t cores = 0;
				noe_get_core_count(ctx, p, c, &cores);
				printf("      cluster %u: %u core(s)\n", c, cores);
			}
		}
	}

	check("noe_deinit_context", noe_deinit_context(ctx));
	puts("OK");
	return 0;
}

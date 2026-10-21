// Read public process counters. No simulator or application state is changed.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>

static void print_json_name(const char *name) {
  putchar('"');
  for (const unsigned char *byte = (const unsigned char *)name; *byte; byte++) {
    if (*byte == '"' || *byte == '\\') printf("\\%c", *byte);
    else if (*byte < 32 || *byte >= 127) printf("\\u%04x", *byte);
    else putchar(*byte);
  }
  putchar('"');
}

int main(void) {
  mach_timebase_info_data_t timebase = {0};
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 6;
  const int initial_count = proc_listallpids(NULL, 0);
  if (initial_count <= 0) return 2;
  const size_t capacity = (size_t)initial_count + 1024;
  pid_t *pids = calloc(capacity, sizeof(pid_t));
  if (!pids) return 3;
  const int count = proc_listallpids(pids, (int)(capacity * sizeof(pid_t)));
  if (count <= 0 || (size_t)count >= capacity) { free(pids); return 4; }
  int written = 0;
  printf("{\"source\":\"publicLibproc\",\"timebaseNumer\":%u,\"timebaseDenom\":%u,\"rows\":[",
    timebase.numer, timebase.denom);
  for (int index = 0; index < count; index++) {
    const pid_t pid = pids[index];
    if (pid <= 0) continue;
    struct proc_bsdinfo bsd = {0};
    struct rusage_info_v4 usage = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) continue;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) continue;
    // XNU exposes these counters in Mach ticks, including on Apple silicon.
    const __uint128_t ticks = (__uint128_t)usage.ri_user_time + usage.ri_system_time;
    const __uint128_t nanoseconds = ticks * timebase.numer / timebase.denom;
    if (nanoseconds > UINT64_MAX) { free(pids); return 7; }
    char name[2 * MAXCOMLEN + 1] = {0};
    memcpy(name, bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm,
      bsd.pbi_name[0] ? sizeof(bsd.pbi_name) : sizeof(bsd.pbi_comm));
    if (written++) putchar(',');
    printf("{\"pid\":%d,\"ppid\":%u,\"start\":%llu,\"name\":", pid,
      bsd.pbi_ppid, (unsigned long long)usage.ri_proc_start_abstime);
    print_json_name(name);
    printf(",\"footprintBytes\":%llu,\"cpuTimeNs\":%llu}",
      (unsigned long long)usage.ri_phys_footprint,
      (unsigned long long)nanoseconds);
  }
  printf("]}\n");
  free(pids);
  return written > 0 ? 0 : 5;
}

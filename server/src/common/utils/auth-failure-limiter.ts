import { HttpException, HttpStatus } from '@nestjs/common';

interface Entry {
  failures: number;
  resetAt: number;
}

const MAX_TRACKED_KEYS = 10_000;

/** In-memory limiter that counts only failed credential checks, so valid sync clients are never throttled. */
export class AuthFailureLimiter {
  private readonly entries = new Map<string, Entry>();

  constructor(
    private readonly maxFailures = 10,
    private readonly windowMs = 15 * 60 * 1000,
  ) {}

  assertAllowed(...keys: string[]): void {
    const now = Date.now();
    for (const key of keys) {
      const entry = this.entries.get(key);
      if (!entry) continue;
      if (entry.resetAt <= now) {
        this.entries.delete(key);
        continue;
      }
      if (entry.failures >= this.maxFailures) {
        throw new HttpException('Too many failed attempts. Try again later.', HttpStatus.TOO_MANY_REQUESTS);
      }
    }
  }

  recordFailure(...keys: string[]): void {
    const now = Date.now();
    for (const key of keys) {
      const entry = this.entries.get(key);
      if (entry && entry.resetAt > now) {
        entry.failures += 1;
        continue;
      }
      if (this.entries.size >= MAX_TRACKED_KEYS) this.prune(now);
      if (this.entries.size >= MAX_TRACKED_KEYS) this.entries.delete(this.entries.keys().next().value as string);
      this.entries.set(key, { failures: 1, resetAt: now + this.windowMs });
    }
  }

  reset(...keys: string[]): void {
    for (const key of keys) this.entries.delete(key);
  }

  private prune(now: number): void {
    for (const [key, entry] of this.entries) {
      if (entry.resetAt <= now) this.entries.delete(key);
    }
  }
}

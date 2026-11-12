import { HttpException } from '@nestjs/common';

import { AuthFailureLimiter } from './auth-failure-limiter';

describe('AuthFailureLimiter', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('blocks a key after the failure limit and allows it again after the window', () => {
    vi.useFakeTimers();
    const limiter = new AuthFailureLimiter(2, 1000);

    limiter.recordFailure('a');
    expect(() => limiter.assertAllowed('a')).not.toThrow();
    limiter.recordFailure('a');
    expect(() => limiter.assertAllowed('a')).toThrow(HttpException);
    expect(() => limiter.assertAllowed('b')).not.toThrow();

    vi.advanceTimersByTime(1001);
    expect(() => limiter.assertAllowed('a')).not.toThrow();
  });

  it('clears failures on reset', () => {
    const limiter = new AuthFailureLimiter(1, 1000);
    limiter.recordFailure('a');
    limiter.reset('a');
    expect(() => limiter.assertAllowed('a')).not.toThrow();
  });
});

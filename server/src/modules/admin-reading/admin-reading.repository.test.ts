import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { DB } from '../../db';
import { AdminReadingRepository } from './admin-reading.repository';

describe('AdminReadingRepository query boundaries', () => {
  const dialect = new PgDialect();
  const statements: { sql: string; params: unknown[] }[] = [];
  let repository: AdminReadingRepository;
  const window = { since: new Date('2026-10-28T00:00:00Z'), until: new Date('2026-11-26T18:00:00Z') };

  beforeEach(async () => {
    statements.length = 0;
    const db = {
      execute: vi.fn((query: SQL) => {
        const statement = dialect.sqlToQuery(query);
        statements.push({ sql: statement.sql.replace(/\s+/g, ' ').trim(), params: statement.params });
        return Promise.resolve({ rows: statement.sql.includes(' as total') ? [{ total: 0 }] : [] });
      }),
    };
    const module = await Test.createTestingModule({ providers: [AdminReadingRepository, { provide: DB, useValue: db }] }).compile();
    repository = module.get(AdminReadingRepository);
  });

  it('uses positive-duration sessions and non-deleted completions in a bounded period', async () => {
    await repository.overview(window);
    expect(statements).toHaveLength(3);
    for (const statement of statements) {
      expect(statement.sql).toContain('duration_seconds > 0');
      expect(statement.params).toContain(window.since);
      expect(statement.params).toContain(window.until);
    }
    expect(statements[0].sql).toContain("outcome = 'completed' and deleted_at is null");
    expect(statements[0].sql).toContain('count(distinct user_id)');
    expect(statements[0].sql).toContain("session_type in ('tts', 'listen')");
  });

  it('keeps search parameters literal and pages accounts in the database', async () => {
    await repository.readers(window, 2, 25, "a_%' OR 1=1");
    expect(statements[0].params).toContain("%a\\_\\%' OR 1=1%");
    expect(statements[0].sql).not.toContain('OR 1=1');
    expect(statements[0].sql).toMatch(/limit \$\d+ offset \$\d+/);
    expect(statements[0].params.slice(-2)).toEqual([25, 25]);
    expect(statements[0].sql).toContain('user_id = u.id');
  });

  it('scopes all book progress sources to one reader and chooses latest rather than maximum progress', async () => {
    await repository.books(window, 9, 2, 25);
    expect(statements).toHaveLength(2);
    expect(statements[0].sql).toContain('p.percentage * 100');
    expect(statements[0].sql).toContain('p.orphaned = false');
    expect(statements[0].sql).toContain('order by book_id, at desc, priority desc, percentage asc');
    expect(statements[0].sql).toContain('coalesce(p.text_updated_at, p.last_read_at)');
    expect(statements[0].sql).not.toContain('max(percentage)');
    expect(statements[0].sql).toMatch(/s.user_id = \$\d+/);
    expect(statements[0].params.filter((value) => typeof value === 'number').every((value) => [9, 25].includes(value))).toBe(true);
  });

  it('pages only achievements actually awarded to this user, including earned hidden achievements', async () => {
    await repository.achievements(9, 3, 25);
    expect(statements[0].sql).toMatch(/ua.user_id = \$\d+/);
    expect(statements[0].sql).toContain('join "achievements"');
    expect(statements[0].sql).not.toContain('hidden');
    expect(statements[0].params).toEqual([9, 25, 50]);
  });
});

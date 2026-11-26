import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { AdminReadingAchievement, AdminReadingBook, AdminReadingOverview, AdminReadingReader } from '@bookorbit/types';

import { DB } from '../../db';
import * as schema from '../../db/schema';

type SqlRow<T> = { [K in keyof T]: T[K] };

export interface AdminReadingWindow {
  since: Date;
  until: Date;
}

@Injectable()
export class AdminReadingRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  async overview(window: AdminReadingWindow) {
    const { since, until } = window;
    const [metrics, trend, sources] = await Promise.all([
      this.db.execute<Omit<AdminReadingOverview, 'periodDays' | 'since' | 'until' | 'trend' | 'sources'>>(sql`
        select count(*)::int as sessions,
          coalesce(sum(duration_seconds), 0)::double precision as "totalSeconds",
          coalesce(sum(duration_seconds) filter (where session_type = 'read'), 0)::double precision as "readingSeconds",
          coalesce(sum(duration_seconds) filter (where session_type in ('tts', 'listen')), 0)::double precision as "listeningSeconds",
          count(distinct (started_at at time zone 'UTC')::date)::int as "activeDays",
          count(distinct user_id)::int as "activeReaders",
          count(distinct book_id)::int as "booksRead",
          (select count(*)::int from ${schema.users}) as "totalUsers",
          (select count(*)::int from ${schema.readingAttempts}
            where outcome = 'completed' and deleted_at is null
              and ended_on >= ${since.toISOString().slice(0, 10)}::date
              and ended_on <= ${until.toISOString().slice(0, 10)}::date) as completions,
          (select count(*)::int from ${schema.userAchievements}
            where awarded_at >= ${since} and awarded_at <= ${until}) as "achievementsEarned"
        from ${schema.readingSessions}
        where started_at >= ${since} and started_at <= ${until} and duration_seconds > 0
      `),
      this.db.execute<AdminReadingOverview['trend'][number]>(sql`
        select to_char(started_at at time zone 'UTC', 'YYYY-MM-DD') as day,
          sum(duration_seconds)::double precision as seconds, count(*)::int as sessions,
          count(distinct user_id)::int as readers
        from ${schema.readingSessions}
        where started_at >= ${since} and started_at <= ${until} and duration_seconds > 0
        group by day order by day
      `),
      this.db.execute<AdminReadingOverview['sources'][number]>(sql`
        select coalesce(source, 'unknown') as source,
          sum(duration_seconds)::double precision as seconds, count(*)::int as sessions
        from ${schema.readingSessions}
        where started_at >= ${since} and started_at <= ${until} and duration_seconds > 0
        group by source order by seconds desc, source
      `),
    ]);
    return { ...metrics.rows[0], trend: trend.rows, sources: sources.rows };
  }

  async readers(window: AdminReadingWindow, page: number, pageSize: number, search?: string) {
    const pattern = `%${(search?.trim() ?? '').replace(/[\\%_]/g, '\\$&')}%`;
    const where = sql`u.name ilike ${pattern} or u.username ilike ${pattern}`;
    const [items, total] = await Promise.all([
      this.db.execute<SqlRow<AdminReadingReader>>(sql`
        select u.id as "userId", u.name, u.username, stats.*,
          ${this.completions(window, sql`u.id`)} as completions
        from ${schema.users} u
        cross join lateral (${this.readerMetrics(window, sql`u.id`)}) stats
        where ${where}
        order by stats."totalSeconds" desc, u.id
        limit ${pageSize} offset ${(page - 1) * pageSize}
      `),
      this.db.execute<{ total: number }>(sql`select count(*)::int as total from ${schema.users} u where ${where}`),
    ]);
    return { items: items.rows, total: total.rows[0].total, page, pageSize };
  }

  async reader(window: AdminReadingWindow, userId: number) {
    const result = await this.db.execute<SqlRow<AdminReadingReader>>(sql`
      select u.id as "userId", u.name, u.username, stats.*,
        ${this.completions(window, sql`u.id`)} as completions
      from ${schema.users} u
      cross join lateral (${this.readerMetrics(window, sql`u.id`)}) stats
      where u.id = ${userId}
    `);
    return result.rows[0];
  }

  private readerMetrics({ since, until }: AdminReadingWindow, userId: SQL) {
    return sql`
      select count(*)::int as sessions,
        coalesce(sum(duration_seconds), 0)::double precision as "totalSeconds",
        coalesce(sum(duration_seconds) filter (where session_type = 'read'), 0)::double precision as "readingSeconds",
        coalesce(sum(duration_seconds) filter (where session_type in ('tts', 'listen')), 0)::double precision as "listeningSeconds",
        count(distinct (started_at at time zone 'UTC')::date)::int as "activeDays",
        to_char(max(ended_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') as "lastReadAt"
      from ${schema.readingSessions}
      where user_id = ${userId} and started_at >= ${since} and started_at <= ${until} and duration_seconds > 0
    `;
  }

  private completions({ since, until }: AdminReadingWindow, userId: SQL) {
    return sql`(select count(*)::int from ${schema.readingAttempts}
      where user_id = ${userId} and outcome = 'completed' and deleted_at is null
        and ended_on >= ${since.toISOString().slice(0, 10)}::date
        and ended_on <= ${until.toISOString().slice(0, 10)}::date)`;
  }

  async books({ since, until }: AdminReadingWindow, userId: number, page: number, pageSize: number) {
    // Select the freshest recorded position, not the furthest, so rereads and resets stay honest.
    const positions = sql`
      select f.book_id, p.percentage, coalesce(p.text_updated_at, p.last_read_at) as at, 1 as priority
      from ${schema.readingProgress} p join ${schema.bookFiles} f on f.id = p.book_file_id
      where p.user_id = ${userId}
      union all
      select f.book_id, p.narration_percentage, p.narration_updated_at, 1
      from ${schema.readingProgress} p join ${schema.bookFiles} f on f.id = p.book_file_id
      where p.user_id = ${userId} and p.narration_percentage is not null
      union all
      select p.book_id, p.percentage, p.updated_at, 1 from ${schema.audiobookProgress} p
      where p.user_id = ${userId}
      union all
      select f.book_id, p.percentage * 100, p.updated_at, 1
      from ${schema.koreaderDeviceProgress} p join ${schema.bookFiles} f on f.id = p.book_file_id
      where p.user_id = ${userId} and p.orphaned = false and p.percentage is not null
    `;
    const ctes = sql`
      with positions as (${positions}),
      latest as (
        select distinct on (book_id) book_id, percentage, at
        from positions where at <= ${until}
        order by book_id, at desc, priority desc, percentage asc
      ),
      activity as (
        select book_id, max(ended_at) as at, count(*)::int as sessions,
          sum(duration_seconds)::double precision as seconds
        from ${schema.readingSessions}
        where user_id = ${userId} and started_at >= ${since} and started_at <= ${until} and duration_seconds > 0
        group by book_id
      ),
      candidates as (
        select book_id from latest where at >= ${since}
        union select book_id from activity
        union select book_id from ${schema.userBookStatus}
          where user_id = ${userId} and status not in ('unread', 'want_to_read')
            and updated_at >= ${since} and updated_at <= ${until}
      )
    `;
    const [items, total] = await Promise.all([
      this.db.execute<SqlRow<AdminReadingBook>>(sql`
        ${ctes}, selected_books as (
          select c.book_id
          from candidates c
          left join latest p on p.book_id = c.book_id
          left join activity a on a.book_id = c.book_id
          left join ${schema.userBookStatus} s on s.book_id = c.book_id and s.user_id = ${userId}
          order by greatest(p.at, a.at, s.updated_at) desc nulls last, c.book_id
          limit ${pageSize} offset ${(page - 1) * pageSize}
        )
        select c.book_id as "bookId", m.title, s.status, p.percentage,
          to_char(greatest(p.at, a.at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') as "lastReadAt",
          coalesce(a.sessions, 0) as sessions, coalesce(a.seconds, 0)::double precision as "totalSeconds"
        from selected_books c
        left join lateral (
          select percentage, at from (
            select percentage, at, 1 as priority from latest where book_id = c.book_id
            union all
            (select end_progress, ended_at, 0 from ${schema.readingSessions}
              where user_id = ${userId} and book_id = c.book_id and end_progress is not null and ended_at <= ${until}
              order by ended_at desc, id desc limit 1)
          ) recorded_positions
          order by at desc, priority desc limit 1
        ) p on true
        left join activity a on a.book_id = c.book_id
        left join ${schema.bookMetadata} m on m.book_id = c.book_id
        left join ${schema.userBookStatus} s on s.book_id = c.book_id and s.user_id = ${userId}
        order by greatest(p.at, a.at, s.updated_at) desc nulls last, c.book_id
      `),
      this.db.execute<{ total: number }>(sql`${ctes} select count(*)::int as total from candidates`),
    ]);
    return { items: items.rows, total: total.rows[0].total, page, pageSize };
  }

  async achievements(userId: number, page: number, pageSize: number) {
    const [items, total] = await Promise.all([
      this.db.execute<SqlRow<AdminReadingAchievement>>(sql`
        select a.key, a.name, a.description, a.rarity,
          to_char(ua.awarded_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') as "awardedAt"
        from ${schema.userAchievements} ua
        join ${schema.achievements} a on a.key = ua.achievement_key
        where ua.user_id = ${userId}
        order by ua.awarded_at desc, ua.id desc
        limit ${pageSize} offset ${(page - 1) * pageSize}
      `),
      this.db.execute<{ total: number }>(sql`select count(*)::int as total from ${schema.userAchievements} where user_id = ${userId}`),
    ]);
    return { items: items.rows, total: total.rows[0].total, page, pageSize };
  }
}

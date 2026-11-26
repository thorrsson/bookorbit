import { ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { AuditAction, AuditResource, Permission } from '@bookorbit/types';
import type { AdminReadingDetail, AdminReadingOverview, AdminReadingPage, AdminReadingReader } from '@bookorbit/types';

import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { AuditService } from '../audit/audit.service';
import { AdminReadingRepository } from './admin-reading.repository';
import type { AdminReadingDetailDto, AdminReadingPeriodDto, AdminReadingReadersDto } from './dto/admin-reading-query.dto';

const DETAIL_PAGE_SIZE = 25;

@Injectable()
export class AdminReadingService {
  private readonly logger = new Logger(AdminReadingService.name);

  constructor(
    private readonly repository: AdminReadingRepository,
    private readonly audit: AuditService,
  ) {}

  overview(viewer: RequestUser, query: AdminReadingPeriodDto): Promise<AdminReadingOverview> {
    return this.run(viewer, 'overview', async () => {
      const window = this.window(query.days);
      await this.record(viewer, undefined, { days: query.days, surface: 'overview' });
      const result = await this.repository.overview(window);
      return { ...result, periodDays: query.days, since: window.since.toISOString(), until: window.until.toISOString() };
    });
  }

  readers(viewer: RequestUser, query: AdminReadingReadersDto): Promise<AdminReadingPage<AdminReadingReader>> {
    return this.run(viewer, 'readers', async () => {
      const result = await this.repository.readers(this.window(query.days), query.page, query.pageSize, query.search);
      for (let offset = 0; offset < result.items.length; offset += 5) {
        await Promise.all(
          result.items.slice(offset, offset + 5).map((reader) => this.record(viewer, reader.userId, { days: query.days, surface: 'readers' })),
        );
      }
      return result;
    });
  }

  detail(viewer: RequestUser, userId: number, query: AdminReadingDetailDto): Promise<AdminReadingDetail> {
    return this.run(viewer, 'detail', async () => {
      const window = this.window(query.days);
      const reader = await this.repository.reader(window, userId);
      if (!reader) throw new NotFoundException('User not found');
      await this.record(viewer, userId, { days: query.days, surface: 'detail' });
      const [books, achievements] = await Promise.all([
        this.repository.books(window, userId, query.booksPage, DETAIL_PAGE_SIZE),
        this.repository.achievements(userId, query.achievementsPage, DETAIL_PAGE_SIZE),
      ]);
      return { reader, books, achievements };
    });
  }

  private window(days: number) {
    const until = new Date();
    const since = new Date(until);
    since.setUTCHours(0, 0, 0, 0);
    since.setUTCDate(since.getUTCDate() - (days - 1));
    return { since, until };
  }

  private record(viewer: RequestUser, userId: number | undefined, meta: Record<string, unknown>) {
    return this.audit.record({
      userId: viewer.id,
      actorUsername: viewer.username,
      action: AuditAction.ReadingInsightsProfileView,
      resource: AuditResource.ReadingInsightsProfile,
      resourceId: userId,
      description: userId === undefined ? 'Viewed administrator reading overview' : `Viewed administrator reading activity for user #${userId}`,
      meta: { ...meta, adminOverride: true, sharingLevel: 'detailed' },
    });
  }

  private async run<T>(viewer: RequestUser, phase: string, operation: () => Promise<T>): Promise<T> {
    if (!viewer.isSuperuser && !viewer.permissions.includes(Permission.ViewReadingActivity)) {
      throw new ForbiddenException('Missing permission: view_reading_activity');
    }
    // A library-restricted credential cannot be used to read platform-wide private activity.
    if (viewer.credential?.kind === 'api_key' && viewer.credential.libraryIds !== null) {
      throw new ForbiddenException('Library-restricted API keys cannot access administrator reading activity');
    }
    const start = Date.now();
    this.logger.log(`[admin.reading] [start] userId=${viewer.id} operation=${phase} - reading dashboard requested`);
    try {
      const result = await operation();
      this.logger.log(`[admin.reading] [end] userId=${viewer.id} operation=${phase} durationMs=${Date.now() - start} - reading dashboard loaded`);
      return result;
    } catch (error: unknown) {
      this.logger.error(
        `[admin.reading] [fail] userId=${viewer.id} operation=${phase} durationMs=${Date.now() - start} errorClass=${error instanceof Error ? error.constructor.name : 'Error'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - reading dashboard failed`,
      );
      throw error;
    }
  }
}

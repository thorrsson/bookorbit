import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { EMPTY_CONTENT_FILTER_RULES, Permission } from '@bookorbit/types';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { RequestUser } from '../../common/types/request-user';
import { AuditService } from '../audit/audit.service';
import { AdminReadingRepository } from './admin-reading.repository';
import { AdminReadingService } from './admin-reading.service';
import { AdminReadingDetailDto, AdminReadingPeriodDto, AdminReadingReadersDto } from './dto/admin-reading-query.dto';

function viewer(overrides: Partial<RequestUser> = {}): RequestUser {
  return {
    id: 1,
    username: 'admin',
    name: 'Admin',
    email: null,
    active: true,
    isSuperuser: false,
    isDefaultPassword: false,
    tokenVersion: 1,
    settings: {},
    avatarUrl: null,
    provisioningMethod: 'local',
    permissions: [Permission.ViewReadingActivity],
    contentFilters: EMPTY_CONTENT_FILTER_RULES,
    ...overrides,
  };
}

describe('AdminReadingService', () => {
  const repository = {
    overview: vi.fn(),
    readers: vi.fn(),
    reader: vi.fn(),
    books: vi.fn(),
    achievements: vi.fn(),
  };
  const audit = { record: vi.fn() };
  let service: AdminReadingService;

  beforeEach(async () => {
    vi.resetAllMocks();
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-11-26T18:00:00Z'));
    const module = await Test.createTestingModule({
      providers: [AdminReadingService, { provide: AdminReadingRepository, useValue: repository }, { provide: AuditService, useValue: audit }],
    }).compile();
    service = module.get(AdminReadingService);
  });
  afterEach(() => vi.useRealTimers());

  it('rejects ordinary users and account-activity admins before querying private reading data', async () => {
    for (const permissions of [[], [Permission.ViewUserActivity], [Permission.ManageUsers]]) {
      await expect(service.overview(viewer({ permissions }), new AdminReadingPeriodDto())).rejects.toBeInstanceOf(ForbiddenException);
      await expect(service.readers(viewer({ permissions }), new AdminReadingReadersDto())).rejects.toBeInstanceOf(ForbiddenException);
      await expect(service.detail(viewer({ permissions }), 9, new AdminReadingDetailDto())).rejects.toBeInstanceOf(ForbiddenException);
    }
    expect(repository.overview).not.toHaveBeenCalled();
    expect(repository.readers).not.toHaveBeenCalled();
    expect(repository.reader).not.toHaveBeenCalled();
  });

  it('rejects library-restricted credentials even with administrator access', async () => {
    await expect(
      service.overview(
        viewer({
          isSuperuser: true,
          credential: { kind: 'api_key', keyId: 1, keyName: 'restricted', audience: 'api', access: 'read', libraryIds: [2], ownerIsSuperuser: true },
        }),
        new AdminReadingPeriodDto(),
      ),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(repository.overview).not.toHaveBeenCalled();
  });

  it('builds a bounded UTC period and allows superusers without explicit grants', async () => {
    repository.overview.mockResolvedValue({ sessions: 0, trend: [], sources: [] });
    const result = await service.overview(viewer({ isSuperuser: true, permissions: [] }), new AdminReadingPeriodDto());
    expect(repository.overview).toHaveBeenCalledWith({ since: new Date('2026-10-28T00:00:00Z'), until: new Date('2026-11-26T18:00:00Z') });
    expect(result).toMatchObject({ periodDays: 30, since: '2026-10-28T00:00:00.000Z', until: '2026-11-26T18:00:00.000Z' });
    expect(audit.record).toHaveBeenCalledWith(expect.objectContaining({ userId: 1, meta: expect.objectContaining({ adminOverride: true }) }));
  });

  it('audits every returned reader before returning the paginated list', async () => {
    const result = { items: [{ userId: 9 }, { userId: 10 }], total: 2, page: 2, pageSize: 25 };
    repository.readers.mockResolvedValue(result);
    const query = Object.assign(new AdminReadingReadersDto(), { page: 2, search: 'reader' });
    await expect(service.readers(viewer(), query)).resolves.toEqual(result);
    expect(repository.readers).toHaveBeenCalledWith(expect.any(Object), 2, 25, 'reader');
    expect(audit.record.mock.calls.map(([payload]) => payload.resourceId)).toEqual([9, 10]);
  });

  it('permits private profiles only through the explicit permission and scopes every detail query', async () => {
    repository.reader.mockResolvedValue({ userId: 9, name: 'Private reader' });
    repository.books.mockResolvedValue({ items: [], total: 0, page: 2, pageSize: 25 });
    repository.achievements.mockResolvedValue({ items: [], total: 0, page: 3, pageSize: 25 });
    const query = Object.assign(new AdminReadingDetailDto(), { booksPage: 2, achievementsPage: 3 });
    const result = await service.detail(viewer(), 9, query);
    expect(result.reader.name).toBe('Private reader');
    expect(repository.books).toHaveBeenCalledWith(expect.any(Object), 9, 2, 25);
    expect(repository.achievements).toHaveBeenCalledWith(9, 3, 25);
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        resourceId: 9,
        meta: expect.objectContaining({ adminOverride: true, sharingLevel: 'detailed' }),
      }),
    );
  });

  it('does not return sensitive data if the access audit fails', async () => {
    repository.reader.mockResolvedValue({ userId: 9 });
    audit.record.mockRejectedValue(new Error('audit unavailable'));
    await expect(service.detail(viewer(), 9, new AdminReadingDetailDto())).rejects.toThrow('audit unavailable');
    expect(repository.books).not.toHaveBeenCalled();
    expect(repository.achievements).not.toHaveBeenCalled();
  });

  it('returns not found for deleted users without fetching details', async () => {
    repository.reader.mockResolvedValue(undefined);
    await expect(service.detail(viewer(), 9, new AdminReadingDetailDto())).rejects.toBeInstanceOf(NotFoundException);
    expect(repository.books).not.toHaveBeenCalled();
    expect(audit.record).not.toHaveBeenCalled();
  });
});

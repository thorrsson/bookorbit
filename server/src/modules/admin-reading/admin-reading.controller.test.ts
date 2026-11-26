import 'reflect-metadata';
import { Permission } from '@bookorbit/types';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { describe, expect, it, vi } from 'vitest';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Reflector } from '@nestjs/core';
import { FastifyAdapter, type NestFastifyApplication } from '@nestjs/platform-fastify';
import { PermissionGuard } from '../../common/guards/permission.guard';
import { PermissionService } from '../../common/services/permission.service';
import { PERMISSION_KEY } from '../../common/decorators/require-permission.decorator';
import { AdminReadingController } from './admin-reading.controller';
import { AdminReadingService } from './admin-reading.service';
import { AdminReadingDetailDto, AdminReadingPeriodDto, AdminReadingReadersDto } from './dto/admin-reading-query.dto';

describe('Admin reading API boundary', () => {
  it('serves the frontend routes, forwards the current user, validates queries, and rejects missing permissions', async () => {
    const service = {
      overview: vi.fn().mockResolvedValue({ sessions: 3 }),
      readers: vi.fn().mockResolvedValue({ items: [] }),
      detail: vi.fn().mockResolvedValue({ books: { items: [] } }),
    };
    const module = await Test.createTestingModule({
      controllers: [AdminReadingController],
      providers: [{ provide: AdminReadingService, useValue: service }],
    }).compile();
    const app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.setGlobalPrefix('api/v1');
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    app.useGlobalGuards(new PermissionGuard(new Reflector(), new PermissionService()));
    app
      .getHttpAdapter()
      .getInstance()
      .addHook('onRequest', (request: FastifyRequest, _reply: FastifyReply, done: () => void) => {
        Object.assign(request, {
          user: {
            id: 1,
            username: 'admin',
            isSuperuser: false,
            permissions: request.headers['x-test-permission'] ? [Permission.ViewReadingActivity] : [],
          },
        });
        done();
      });
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
    try {
      const headers = { 'x-test-permission': 'granted' };
      const overview = await app.inject({ method: 'GET', url: '/api/v1/admin/reading/overview?days=90', headers });
      expect(overview.statusCode).toBe(200);
      expect(overview.json()).toEqual({ sessions: 3 });
      expect(service.overview).toHaveBeenCalledWith(expect.objectContaining({ id: 1 }), expect.objectContaining({ days: 90 }));
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/reading/readers?page=2&pageSize=25&search=reader', headers })).statusCode).toBe(
        200,
      );
      expect(service.readers).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ days: 30, page: 2, pageSize: 25, search: 'reader' }),
      );
      expect(
        (await app.inject({ method: 'GET', url: '/api/v1/admin/reading/readers/9?days=90&booksPage=2&achievementsPage=3', headers })).statusCode,
      ).toBe(200);
      expect(service.detail).toHaveBeenCalledWith(expect.any(Object), 9, expect.objectContaining({ days: 90, booksPage: 2, achievementsPage: 3 }));
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/reading/overview?days=9999', headers })).statusCode).toBe(400);
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/reading/readers/invalid', headers })).statusCode).toBe(400);
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/reading/overview' })).statusCode).toBe(403);
      expect(service.overview).toHaveBeenCalledTimes(1);
    } finally {
      await app.close();
    }
  });
  it('protects all endpoints with the dedicated reading permission', () => {
    expect(Reflect.getMetadata(PERMISSION_KEY, AdminReadingController)).toBe(Permission.ViewReadingActivity);
  });

  it('transforms query strings and caps periods, page sizes, and offsets', async () => {
    expect(await validate(plainToInstance(AdminReadingReadersDto, { days: '90', page: '2', pageSize: '25', search: 'reader' }))).toEqual([]);
    for (const input of [{ days: 10000 }, { pageSize: 100 }, { page: -1 }, { page: 1.5 }, { page: 10001 }, { search: 'a'.repeat(101) }]) {
      expect(await validate(plainToInstance(AdminReadingReadersDto, input))).not.toHaveLength(0);
    }
    expect(await validate(plainToInstance(AdminReadingPeriodDto, { days: 0 }))).not.toHaveLength(0);
    expect(await validate(plainToInstance(AdminReadingDetailDto, { booksPage: '2', achievementsPage: '3' }))).toEqual([]);
    expect(await validate(plainToInstance(AdminReadingDetailDto, { achievementsPage: -1 }))).not.toHaveLength(0);
  });

  it('rejects extra frontend fields rather than silently ignoring them', async () => {
    const errors = await validate(plainToInstance(AdminReadingPeriodDto, { days: '30', userId: 9 }), { whitelist: true, forbidNonWhitelisted: true });
    expect(errors[0].property).toBe('userId');
  });
});

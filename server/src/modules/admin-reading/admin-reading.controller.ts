import { Controller, Get, Param, ParseIntPipe, Query } from '@nestjs/common';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { AdminReadingService } from './admin-reading.service';
import { AdminReadingDetailDto, AdminReadingPeriodDto, AdminReadingReadersDto } from './dto/admin-reading-query.dto';

@Controller('admin/reading')
@RequirePermission(Permission.ViewReadingActivity)
export class AdminReadingController {
  constructor(private readonly service: AdminReadingService) {}

  @Get('overview')
  overview(@CurrentUser() viewer: RequestUser, @Query() query: AdminReadingPeriodDto) {
    return this.service.overview(viewer, query);
  }

  @Get('readers')
  readers(@CurrentUser() viewer: RequestUser, @Query() query: AdminReadingReadersDto) {
    return this.service.readers(viewer, query);
  }

  @Get('readers/:userId')
  detail(@CurrentUser() viewer: RequestUser, @Param('userId', ParseIntPipe) userId: number, @Query() query: AdminReadingDetailDto) {
    return this.service.detail(viewer, userId, query);
  }
}

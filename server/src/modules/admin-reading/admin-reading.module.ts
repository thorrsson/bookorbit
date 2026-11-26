import { Module } from '@nestjs/common';

import { AuditModule } from '../audit/audit.module';
import { AdminReadingController } from './admin-reading.controller';
import { AdminReadingRepository } from './admin-reading.repository';
import { AdminReadingService } from './admin-reading.service';

@Module({
  imports: [AuditModule],
  controllers: [AdminReadingController],
  providers: [AdminReadingRepository, AdminReadingService],
})
export class AdminReadingModule {}

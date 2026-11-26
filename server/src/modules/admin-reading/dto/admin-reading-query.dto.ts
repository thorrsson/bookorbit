import { Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';

export class AdminReadingPeriodDto {
  @Type(() => Number)
  @IsInt()
  @IsIn([30, 90, 365])
  days = 30;
}

export class AdminReadingReadersDto extends AdminReadingPeriodDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(10000)
  page = 1;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(50)
  pageSize = 25;

  @IsOptional()
  @IsString()
  @MaxLength(100)
  search?: string;
}

export class AdminReadingDetailDto extends AdminReadingPeriodDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(10000)
  booksPage = 1;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(10000)
  achievementsPage = 1;
}

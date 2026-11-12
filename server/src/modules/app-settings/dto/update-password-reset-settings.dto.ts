import { IsInt, Max, Min } from 'class-validator';
import { MAX_PASSWORD_RESET_LIFETIME_MINUTES } from '@bookorbit/types';

export class UpdatePasswordResetSettingsDto {
  @IsInt()
  @Min(1)
  @Max(MAX_PASSWORD_RESET_LIFETIME_MINUTES)
  lifetimeMinutes: number;
}

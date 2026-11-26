import type { ReadStatus } from "./book";
import type { ReadingSessionSource } from "./reading-session";

export interface AdminReadingPage<T> {
  items: T[];
  total: number;
  page: number;
  pageSize: number;
}

export interface AdminReadingMetrics {
  sessions: number;
  totalSeconds: number;
  readingSeconds: number;
  listeningSeconds: number;
  activeDays: number;
  completions: number;
}

export interface AdminReadingReader extends AdminReadingMetrics {
  userId: number;
  name: string;
  username: string;
  lastReadAt: string | null;
}

export interface AdminReadingOverview extends AdminReadingMetrics {
  periodDays: number;
  since: string;
  until: string;
  totalUsers: number;
  activeReaders: number;
  booksRead: number;
  achievementsEarned: number;
  trend: { day: string; seconds: number; sessions: number; readers: number }[];
  sources: { source: ReadingSessionSource | "unknown"; seconds: number; sessions: number }[];
}

export interface AdminReadingBook {
  bookId: number;
  title: string | null;
  status: ReadStatus | null;
  percentage: number | null;
  lastReadAt: string | null;
  sessions: number;
  totalSeconds: number;
}

export interface AdminReadingAchievement {
  key: string;
  name: string;
  description: string;
  rarity: string;
  awardedAt: string;
}

export interface AdminReadingDetail {
  reader: AdminReadingReader;
  books: AdminReadingPage<AdminReadingBook>;
  achievements: AdminReadingPage<AdminReadingAchievement>;
}

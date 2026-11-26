<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { ArrowLeft, ShieldCheck } from '@lucide/vue'
import { Button } from '@/components/ui/button'
import { formatDateTime, formatNumber } from '@/i18n/formatters'
import { useAdminReading } from './composables/useAdminReading'
import ReadingPagination from './components/ReadingPagination.vue'
import AdminReadingTrend from './components/AdminReadingTrend.vue'

const { t } = useI18n()
const dashboard = useAdminReading()
onMounted(dashboard.load)
const metrics = computed(() => {
  const data = dashboard.overview.value
  if (!data) return []
  return [
    {
      key: 'activeReaders',
      value: t('adminFeature.reading.activeRatio', { active: formatNumber(data.activeReaders), total: formatNumber(data.totalUsers) }),
    },
    { key: 'readingTime', value: duration(data.readingSeconds) },
    { key: 'listeningTime', value: duration(data.listeningSeconds) },
    { key: 'sessions', value: formatNumber(data.sessions) },
    { key: 'averageSession', value: duration(data.sessions ? data.totalSeconds / data.sessions : 0) },
    { key: 'booksRead', value: formatNumber(data.booksRead) },
    { key: 'completions', value: formatNumber(data.completions) },
    { key: 'achievements', value: formatNumber(data.achievementsEarned) },
  ]
})

function duration(seconds: number) {
  const minutes = Math.round(seconds / 60)
  return minutes < 60
    ? t('adminFeature.sharedInsights.durationMinutes', { count: minutes })
    : t('adminFeature.sharedInsights.durationHours', { count: Math.round(minutes / 6) / 10 })
}
function dateLabel(value: string | null) {
  return value ? formatDateTime(new Date(value)) : t('adminFeature.reading.notRecorded')
}
function progressLabel(percentage: number | null) {
  return percentage === null ? t('adminFeature.reading.notRecorded') : `${formatNumber(percentage, { maximumFractionDigits: 1 })}%`
}
function changeReaderPage(page: number) {
  dashboard.page.value = page
  void dashboard.load()
}
function changeBooksPage(page: number) {
  dashboard.booksPage.value = page
  void dashboard.loadDetail()
}
function changeAchievementsPage(page: number) {
  dashboard.achievementsPage.value = page
  void dashboard.loadDetail()
}
</script>

<template>
  <section class="space-y-6">
    <p v-if="!dashboard.allowed.value" role="alert" class="text-sm text-destructive">{{ t('adminFeature.reading.forbidden') }}</p>
    <template v-else>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p class="flex max-w-2xl items-start gap-2 text-sm text-muted-foreground">
          <ShieldCheck :size="16" class="mt-0.5 shrink-0" aria-hidden="true" />
          {{ t('adminFeature.reading.auditNotice') }}
        </p>
        <label class="shrink-0 text-xs text-muted-foreground">
          <span class="mr-2">{{ t('adminFeature.sharedInsights.period') }}</span>
          <select
            v-model="dashboard.days.value"
            class="h-9 rounded-md border border-input bg-background px-2 text-sm text-foreground"
            @change="dashboard.changePeriod"
          >
            <option v-for="days in [30, 90, 365]" :key="days" :value="days">
              {{ t('adminFeature.sharedInsights.periodDays', { count: days }) }}
            </option>
          </select>
        </label>
      </div>

      <p v-if="dashboard.loading.value" role="status" class="py-8 text-center text-sm text-muted-foreground">{{ t('common.loading') }}</p>
      <div v-else-if="dashboard.error.value" role="alert" class="space-y-3 py-6 text-center">
        <p class="text-sm text-destructive">{{ t('adminFeature.reading.loadError') }}</p>
        <Button variant="outline" @click="dashboard.load">{{ t('common.retry') }}</Button>
      </div>
      <template v-else-if="dashboard.overview.value && dashboard.readers.value">
        <dl class="grid grid-cols-2 gap-x-6 gap-y-4 border-y border-border py-5 sm:grid-cols-4">
          <div v-for="metric in metrics" :key="metric.key" class="min-w-0">
            <dt class="text-xs text-muted-foreground">{{ t(`adminFeature.reading.${metric.key}`) }}</dt>
            <dd class="mt-1 text-lg font-semibold tabular-nums">{{ metric.value }}</dd>
          </div>
        </dl>
        <p class="text-xs leading-relaxed text-muted-foreground">{{ t('adminFeature.reading.coverage') }}</p>

        <div v-if="dashboard.selectedUserId.value === null" class="space-y-6">
          <p v-if="dashboard.overview.value.sessions === 0" class="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
            {{ t('adminFeature.reading.noActivity') }}
          </p>
          <div v-else class="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
            <AdminReadingTrend :overview="dashboard.overview.value" />
            <section>
              <h2 class="text-sm font-semibold">{{ t('adminFeature.reading.sources') }}</h2>
              <ul class="mt-3 divide-y divide-border">
                <li
                  v-for="source in dashboard.overview.value.sources"
                  :key="source.source"
                  class="flex items-center justify-between gap-3 py-3 text-sm"
                >
                  <span>{{ t(`adminFeature.sharedInsights.sourceNames.${source.source}`) }}</span>
                  <span class="text-right text-xs text-muted-foreground"
                    >{{ duration(source.seconds) }}<br />{{ t('adminFeature.reading.sessionCount', { count: source.sessions }) }}</span
                  >
                </li>
              </ul>
            </section>
          </div>
          <section>
            <form class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between" @submit.prevent="dashboard.applySearch">
              <h2 class="text-base font-semibold">{{ t('adminFeature.reading.readers') }}</h2>
              <div class="flex gap-2">
                <input
                  v-model="dashboard.search.value"
                  type="search"
                  maxlength="100"
                  :aria-label="t('adminFeature.accountActivity.filters.search')"
                  :placeholder="t('adminFeature.accountActivity.filters.searchPlaceholder')"
                  class="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm"
                />
                <Button type="submit" variant="outline" size="sm">{{ t('adminFeature.accountActivity.filters.apply') }}</Button>
              </div>
            </form>
            <p v-if="dashboard.readers.value.items.length === 0" class="py-6 text-sm text-muted-foreground">
              {{ t('adminFeature.reading.noReaders') }}
            </p>
            <ul v-else class="mt-3 divide-y divide-border">
              <li v-for="reader in dashboard.readers.value.items" :key="reader.userId" class="grid gap-3 py-4 sm:grid-cols-[minmax(0,1fr)_2fr]">
                <div class="min-w-0">
                  <button
                    class="max-w-full truncate rounded-sm text-left text-sm font-semibold text-primary hover:underline focus-visible:outline-2 focus-visible:outline-ring"
                    :aria-label="t('adminFeature.reading.openReader', { name: reader.name })"
                    @click="dashboard.selectReader(reader.userId)"
                  >
                    {{ reader.name }}
                  </button>
                  <p class="truncate text-xs text-muted-foreground">{{ reader.username }}</p>
                  <p class="mt-1 text-xs text-muted-foreground">{{ t('adminFeature.reading.lastRead') }}: {{ dateLabel(reader.lastReadAt) }}</p>
                </div>
                <dl class="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                  <div>
                    <dt class="text-muted-foreground">{{ t('adminFeature.reading.sessions') }}</dt>
                    <dd class="mt-1 tabular-nums">{{ formatNumber(reader.sessions) }}</dd>
                  </div>
                  <div>
                    <dt class="text-muted-foreground">{{ t('adminFeature.reading.activeDays') }}</dt>
                    <dd class="mt-1 tabular-nums">{{ formatNumber(reader.activeDays) }} / {{ dashboard.days.value }}</dd>
                  </div>
                  <div>
                    <dt class="text-muted-foreground">{{ t('adminFeature.reading.totalTime') }}</dt>
                    <dd class="mt-1">{{ duration(reader.totalSeconds) }}</dd>
                  </div>
                  <div>
                    <dt class="text-muted-foreground">{{ t('adminFeature.reading.completions') }}</dt>
                    <dd class="mt-1 tabular-nums">{{ formatNumber(reader.completions) }}</dd>
                  </div>
                </dl>
              </li>
            </ul>
            <ReadingPagination v-bind="dashboard.readers.value" @change="changeReaderPage" />
          </section>
        </div>
      </template>

      <section v-if="dashboard.selectedUserId.value !== null" class="space-y-4">
        <Button variant="outline" size="sm" @click="dashboard.closeReader"><ArrowLeft :size="15" aria-hidden="true" />{{ t('common.back') }}</Button>
        <p v-if="dashboard.detailLoading.value" role="status" class="py-6 text-sm text-muted-foreground">{{ t('common.loading') }}</p>
        <div v-else-if="dashboard.detailError.value" role="alert" class="space-y-3">
          <p class="text-sm text-destructive">{{ t('adminFeature.reading.detailError') }}</p>
          <Button variant="outline" @click="dashboard.loadDetail">{{ t('common.retry') }}</Button>
        </div>
        <template v-else-if="dashboard.detail.value">
          <h2 class="text-xl font-semibold">{{ dashboard.detail.value.reader.name }}</h2>
          <p class="text-sm text-muted-foreground">
            {{
              t('adminFeature.reading.readerSummary', {
                sessions: dashboard.detail.value.reader.sessions,
                days: dashboard.detail.value.reader.activeDays,
                time: duration(dashboard.detail.value.reader.totalSeconds),
              })
            }}
          </p>
          <section>
            <h3 class="text-sm font-semibold">{{ t('adminFeature.reading.books') }}</h3>
            <p v-if="dashboard.detail.value.books.total === 0" class="py-4 text-sm text-muted-foreground">{{ t('adminFeature.reading.noBooks') }}</p>
            <ul v-else class="mt-2 divide-y divide-border">
              <li
                v-for="book in dashboard.detail.value.books.items"
                :key="book.bookId"
                class="grid items-center gap-3 py-4 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]"
              >
                <div class="min-w-0">
                  <p class="break-words text-sm font-medium">{{ book.title ?? t('adminFeature.sharedInsights.unknownTitle') }}</p>
                  <p class="mt-1 text-xs text-muted-foreground">
                    {{ book.status ? t(`book.readStatus.${book.status}`) : t('adminFeature.reading.notRecorded') }} ·
                    {{ t('adminFeature.reading.sessionCount', { count: book.sessions }) }} · {{ duration(book.totalSeconds) }}
                  </p>
                  <p class="mt-1 text-xs text-muted-foreground">{{ t('adminFeature.reading.lastRead') }}: {{ dateLabel(book.lastReadAt) }}</p>
                </div>
                <div>
                  <p class="text-xs text-muted-foreground">
                    {{ t('adminFeature.reading.progress') }}: <span class="font-medium text-foreground">{{ progressLabel(book.percentage) }}</span>
                  </p>
                  <progress
                    v-if="book.percentage !== null"
                    :value="book.percentage"
                    max="100"
                    :aria-label="t('adminFeature.reading.bookProgress', { title: book.title ?? t('adminFeature.sharedInsights.unknownTitle') })"
                    class="mt-2 h-2 w-full accent-primary"
                  />
                </div>
              </li>
            </ul>
            <ReadingPagination v-bind="dashboard.detail.value.books" @change="changeBooksPage" />
          </section>
          <section class="border-t border-border pt-5">
            <h3 class="text-sm font-semibold">{{ t('adminFeature.reading.earnedAchievements') }}</h3>
            <p class="mt-1 text-xs text-muted-foreground">{{ t('adminFeature.reading.achievementsAllTime') }}</p>
            <p v-if="dashboard.detail.value.achievements.total === 0" class="py-4 text-sm text-muted-foreground">
              {{ t('adminFeature.reading.noAchievements') }}
            </p>
            <ul v-else class="mt-3 divide-y divide-border">
              <li
                v-for="achievement in dashboard.detail.value.achievements.items"
                :key="achievement.key"
                class="flex flex-col justify-between gap-2 py-3 sm:flex-row"
              >
                <div>
                  <p class="text-sm font-medium">{{ achievement.name }}</p>
                  <p class="mt-1 max-w-prose text-xs text-muted-foreground">{{ achievement.description }}</p>
                </div>
                <time :datetime="achievement.awardedAt" class="shrink-0 text-xs text-muted-foreground">{{ dateLabel(achievement.awardedAt) }}</time>
              </li>
            </ul>
            <ReadingPagination v-bind="dashboard.detail.value.achievements" @change="changeAchievementsPage" />
          </section>
        </template>
      </section>
    </template>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import type { EChartsOption } from 'echarts'
import type { AdminReadingOverview } from '@bookorbit/types'
import AppChart from '@/components/charts/AppChart.vue'
import { formatNumber } from '@/i18n/formatters'

const props = defineProps<{ overview: AdminReadingOverview }>()
const { t } = useI18n()
const points = computed(() => {
  const byDay = new Map(props.overview.trend.map((point) => [point.day, point]))
  return Array.from({ length: props.overview.periodDays }, (_, index) => {
    const date = new Date(props.overview.since)
    date.setUTCDate(date.getUTCDate() + index)
    const day = date.toISOString().slice(0, 10)
    return byDay.get(day) ?? { day, seconds: 0, sessions: 0, readers: 0 }
  })
})
const option = computed<EChartsOption>(() => ({
  animation: false,
  tooltip: { trigger: 'axis' },
  grid: { top: 15, right: 15, bottom: 30, left: 55 },
  xAxis: { type: 'category', data: points.value.map((point) => point.day) },
  yAxis: { type: 'value', name: t('adminFeature.reading.minutes'), min: 0 },
  series: [{ name: t('adminFeature.reading.minutes'), type: 'bar', data: points.value.map((point) => Math.round(point.seconds / 60)) }],
}))
</script>

<template>
  <section class="min-w-0">
    <h2 class="text-sm font-semibold">{{ t('adminFeature.reading.trend') }}</h2>
    <div class="mt-3 h-52 w-full">
      <AppChart :option autoresize style="height: 100%" :aria-label="t('adminFeature.reading.trend')" />
    </div>
    <details class="mt-2 text-xs text-muted-foreground">
      <summary class="cursor-pointer rounded-sm focus-visible:outline-2 focus-visible:outline-ring">{{ t('adminFeature.reading.viewData') }}</summary>
      <div class="mt-3 max-h-64 overflow-auto">
        <table class="w-full text-left">
          <thead>
            <tr>
              <th class="py-2">{{ t('adminFeature.reading.day') }}</th>
              <th>{{ t('adminFeature.reading.minutes') }}</th>
              <th>{{ t('adminFeature.reading.sessions') }}</th>
              <th>{{ t('adminFeature.reading.readers') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="point in points" :key="point.day" class="border-t border-border">
              <td class="py-2">{{ point.day }}</td>
              <td>{{ formatNumber(Math.round(point.seconds / 60)) }}</td>
              <td>{{ formatNumber(point.sessions) }}</td>
              <td>{{ formatNumber(point.readers) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
  </section>
</template>

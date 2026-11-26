<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { Button } from '@/components/ui/button'

const props = defineProps<{ page: number; total: number; pageSize: number }>()
const emit = defineEmits<{ change: [page: number] }>()
const { t } = useI18n()
const pages = computed(() => Math.max(1, Math.ceil(props.total / props.pageSize)))
function previous() {
  emit('change', props.page - 1)
}
function next() {
  emit('change', props.page + 1)
}
</script>

<template>
  <nav v-if="pages > 1" :aria-label="t('common.pagination.label')" class="flex flex-wrap items-center justify-end gap-2 pt-3">
    <span class="mr-auto text-xs text-muted-foreground">{{ t('common.pagination.pageOf', { page, totalPages: pages }) }}</span>
    <Button variant="outline" size="sm" :disabled="page <= 1" @click="previous">{{ t('common.previous') }}</Button>
    <Button variant="outline" size="sm" :disabled="page >= pages" @click="next">{{ t('common.next') }}</Button>
  </nav>
</template>

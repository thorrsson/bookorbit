import { computed, onScopeDispose, ref, watch } from 'vue'
import type { AdminReadingDetail, AdminReadingOverview, AdminReadingPage, AdminReadingReader } from '@bookorbit/types'

import { api } from '@/lib/api'
import { usePermissions } from '@/features/auth/composables/usePermissions'

export function useAdminReading() {
  const { hasPermission } = usePermissions()
  const allowed = computed(() => hasPermission('view_reading_activity'))
  const days = ref(30)
  const search = ref('')
  const page = ref(1)
  const selectedUserId = ref<number | null>(null)
  const booksPage = ref(1)
  const achievementsPage = ref(1)
  const overview = ref<AdminReadingOverview | null>(null)
  const readers = ref<AdminReadingPage<AdminReadingReader> | null>(null)
  const detail = ref<AdminReadingDetail | null>(null)
  const loading = ref(false)
  const detailLoading = ref(false)
  const error = ref(false)
  const detailError = ref(false)
  let listVersion = 0
  let detailVersion = 0
  let listController: AbortController | undefined
  let detailController: AbortController | undefined

  function clear() {
    listVersion++
    detailVersion++
    listController?.abort()
    detailController?.abort()
    overview.value = null
    readers.value = null
    detail.value = null
    selectedUserId.value = null
    loading.value = false
    detailLoading.value = false
  }

  watch(allowed, (value) => {
    if (!value) clear()
  })
  onScopeDispose(clear)

  async function load() {
    if (!allowed.value) return clear()
    const version = ++listVersion
    listController?.abort()
    const controller = new AbortController()
    listController = controller
    loading.value = true
    error.value = false
    overview.value = null
    readers.value = null
    const params = new URLSearchParams({ days: String(days.value), page: String(page.value), pageSize: '25', search: search.value.trim() })
    try {
      const [overviewResponse, readersResponse] = await Promise.all([
        api(`/api/v1/admin/reading/overview?days=${days.value}`, { signal: controller.signal }),
        api(`/api/v1/admin/reading/readers?${params}`, { signal: controller.signal }),
      ])
      if (!overviewResponse.ok || !readersResponse.ok) throw new Error('Reading dashboard could not be loaded')
      const [overviewData, readersData] = await Promise.all([
        overviewResponse.json() as Promise<AdminReadingOverview>,
        readersResponse.json() as Promise<AdminReadingPage<AdminReadingReader>>,
      ])
      if (version !== listVersion || !allowed.value) return
      overview.value = overviewData
      readers.value = readersData
    } catch {
      if (version === listVersion) error.value = true
    } finally {
      if (version === listVersion) loading.value = false
    }
  }

  async function loadDetail() {
    if (!allowed.value || selectedUserId.value === null) return
    const version = ++detailVersion
    detailController?.abort()
    const controller = new AbortController()
    detailController = controller
    detailLoading.value = true
    detailError.value = false
    detail.value = null
    const params = new URLSearchParams({
      days: String(days.value),
      booksPage: String(booksPage.value),
      achievementsPage: String(achievementsPage.value),
    })
    try {
      const response = await api(`/api/v1/admin/reading/readers/${selectedUserId.value}?${params}`, { signal: controller.signal })
      if (!response.ok) throw new Error('Reader details could not be loaded')
      const result = (await response.json()) as AdminReadingDetail
      if (version === detailVersion && allowed.value) detail.value = result
    } catch {
      if (version === detailVersion) detailError.value = true
    } finally {
      if (version === detailVersion) detailLoading.value = false
    }
  }

  function selectReader(userId: number) {
    selectedUserId.value = userId
    booksPage.value = 1
    achievementsPage.value = 1
    void loadDetail()
  }

  function closeReader() {
    detailVersion++
    detailController?.abort()
    selectedUserId.value = null
    detail.value = null
    detailError.value = false
    detailLoading.value = false
  }

  function changePeriod() {
    page.value = 1
    booksPage.value = 1
    achievementsPage.value = 1
    void load()
    if (selectedUserId.value !== null) void loadDetail()
  }

  function applySearch() {
    page.value = 1
    void load()
  }

  return {
    allowed,
    days,
    search,
    page,
    selectedUserId,
    booksPage,
    achievementsPage,
    overview,
    readers,
    detail,
    loading,
    detailLoading,
    error,
    detailError,
    load,
    loadDetail,
    selectReader,
    closeReader,
    changePeriod,
    applySearch,
  }
}

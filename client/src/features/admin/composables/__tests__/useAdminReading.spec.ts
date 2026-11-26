import { effectScope, nextTick, ref } from 'vue'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useAdminReading } from '../useAdminReading'

const allowed = ref(true)
const apiMock = vi.fn<(input: string, init?: RequestInit) => Promise<Response>>()
vi.mock('@/lib/api', () => ({ api: (input: string, init?: RequestInit) => apiMock(input, init) }))
vi.mock('@/features/auth/composables/usePermissions', () => ({ usePermissions: () => ({ hasPermission: () => allowed.value }) }))

const scopes: ReturnType<typeof effectScope>[] = []
function createDashboard() {
  const scope = effectScope()
  scopes.push(scope)
  return scope.run(useAdminReading)!
}
function response(data: unknown) {
  return new Response(JSON.stringify(data))
}

describe('useAdminReading', () => {
  beforeEach(() => {
    allowed.value = true
    vi.resetAllMocks()
  })
  afterEach(() => {
    scopes.splice(0).forEach((scope) => scope.stop())
  })

  it('does not request private reading activity without the permission', async () => {
    allowed.value = false
    const dashboard = createDashboard()
    await dashboard.load()
    expect(apiMock).not.toHaveBeenCalled()
  })

  it('requests the exact paginated API contract and resets pages on a period change', async () => {
    apiMock.mockImplementation(async (url) =>
      response(url.includes('/overview?') ? { periodDays: 90 } : { items: [], total: 0, page: 1, pageSize: 25 }),
    )
    const dashboard = createDashboard()
    dashboard.days.value = 90
    dashboard.page.value = 2
    dashboard.search.value = ' A & B '
    await dashboard.load()
    expect(apiMock.mock.calls[0][0]).toBe('/api/v1/admin/reading/overview?days=90')
    const params = new URL(apiMock.mock.calls[1][0], 'http://localhost').searchParams
    expect(Object.fromEntries(params)).toEqual({ days: '90', page: '2', pageSize: '25', search: 'A & B' })
    dashboard.changePeriod()
    expect(dashboard.page.value).toBe(1)
  })

  it('never restores a stale list after a newer load or permission revocation', async () => {
    let finishOld: (response: Response) => void = () => undefined
    apiMock.mockImplementation((url) =>
      url.includes('days=30')
        ? new Promise((resolve) => {
            if (url.includes('/overview?')) finishOld = resolve
            else resolve(response({ items: [] }))
          })
        : Promise.resolve(response(url.includes('/overview?') ? { periodDays: 90 } : { items: [] })),
    )
    const dashboard = createDashboard()
    const oldLoad = dashboard.load()
    dashboard.days.value = 90
    await dashboard.load()
    finishOld(response({ periodDays: 30 }))
    await oldLoad
    expect(dashboard.overview.value?.periodDays).toBe(90)
    allowed.value = false
    await nextTick()
    expect(dashboard.overview.value).toBeNull()
    expect(dashboard.readers.value).toBeNull()
  })

  it('does not restore details after returning to the list', async () => {
    let finish: (response: Response) => void = () => undefined
    apiMock.mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve
        }),
    )
    const dashboard = createDashboard()
    dashboard.selectedUserId.value = 9
    const load = dashboard.loadDetail()
    dashboard.closeReader()
    finish(response({ reader: { userId: 9 } }))
    await load
    expect(dashboard.detail.value).toBeNull()
    expect(dashboard.selectedUserId.value).toBeNull()
    expect(dashboard.detailLoading.value).toBe(false)
  })

  it('clears previous data and exposes failures rather than showing stale success', async () => {
    apiMock.mockImplementation(async (url) => response(url.includes('/overview?') ? { periodDays: 30 } : { items: [] }))
    const dashboard = createDashboard()
    await dashboard.load()
    apiMock.mockResolvedValue(new Response('{}', { status: 403 }))
    await dashboard.load()
    expect(dashboard.error.value).toBe(true)
    expect(dashboard.overview.value).toBeNull()
    expect(dashboard.readers.value).toBeNull()
  })
})

import { ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import AdminReadingPage from '../AdminReadingPage.vue'

const allowed = ref(true)
const apiMock = vi.fn<(url: string) => Promise<Response>>()
vi.mock('@/lib/api', () => ({ api: (url: string) => apiMock(url) }))
vi.mock('@/features/auth/composables/usePermissions', () => ({ usePermissions: () => ({ hasPermission: () => allowed.value }) }))

const metrics = { sessions: 3, totalSeconds: 1800, readingSeconds: 1200, listeningSeconds: 600, activeDays: 2, completions: 1 }
const reader = { ...metrics, userId: 9, name: 'Reader', username: 'reader', lastReadAt: null }
const overview = {
  ...metrics,
  periodDays: 30,
  since: '2026-10-28T00:00:00Z',
  until: '2026-11-26T18:00:00Z',
  totalUsers: 5,
  activeReaders: 1,
  booksRead: 2,
  achievementsEarned: 1,
  trend: [],
  sources: [],
}
function mountPage() {
  return mount(AdminReadingPage, {
    global: {
      stubs: {
        AdminReadingTrend: true,
        Button: { props: ['disabled'], template: '<button :disabled="disabled"><slot /></button>' },
      },
    },
  })
}

describe('AdminReadingPage', () => {
  beforeEach(() => {
    allowed.value = true
    vi.resetAllMocks()
    apiMock.mockImplementation(
      async (url) =>
        new Response(
          JSON.stringify(
            url.includes('/overview?')
              ? overview
              : url.includes('/readers/9?')
                ? {
                    reader,
                    books: {
                      items: [
                        { bookId: 1, title: 'A reread', status: 'rereading', percentage: 12.5, sessions: 2, totalSeconds: 1200, lastReadAt: null },
                        {
                          bookId: 2,
                          title: 'Unknown progress',
                          status: 'reading',
                          percentage: null,
                          sessions: 1,
                          totalSeconds: 600,
                          lastReadAt: null,
                        },
                      ],
                      total: 30,
                      page: 1,
                      pageSize: 25,
                    },
                    achievements: {
                      items: [{ key: 'first', name: 'First book', description: 'Completed a book', awardedAt: '2026-11-25T12:00:00Z' }],
                      total: 1,
                      page: 1,
                      pageSize: 25,
                    },
                  }
                : { items: [reader], total: 30, page: 1, pageSize: 25 },
          ),
        ),
    )
  })

  it('shows meaningful metrics and opens per-reader progress and earned achievements', async () => {
    const wrapper = mountPage()
    await flushPromises()
    expect(wrapper.text()).toContain('1 of 5 accounts')
    expect(wrapper.text()).toContain('including private profiles')
    expect(wrapper.text()).toContain('Average session')
    await wrapper.get('button[aria-label="View reading details for Reader"]').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('A reread')
    expect(wrapper.text()).toContain('12.5%')
    expect(wrapper.text()).toContain('First book')
    expect(wrapper.findAll('progress')).toHaveLength(1)
    expect(wrapper.get('progress').attributes('value')).toBe('12.5')
    expect(wrapper.text()).toContain('Not recorded')
    expect(wrapper.text()).toContain('All-time earned achievements')
    await wrapper
      .findAll('button')
      .find((button) => button.text() === 'Next')!
      .trigger('click')
    await flushPromises()
    expect(apiMock.mock.calls.some(([url]) => url.includes('booksPage=2&achievementsPage=1'))).toBe(true)
    wrapper.unmount()
  })

  it('hides activity entirely and makes no requests without permission', async () => {
    allowed.value = false
    const wrapper = mountPage()
    await flushPromises()
    expect(wrapper.text()).toContain('You do not have permission')
    expect(apiMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('offers retry on API errors rather than presenting old activity', async () => {
    apiMock.mockResolvedValue(new Response('{}', { status: 500 }))
    const wrapper = mountPage()
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toContain('Could not load reading activity')
    await wrapper
      .findAll('button')
      .find((button) => button.text() === 'Retry')!
      .trigger('click')
    expect(apiMock).toHaveBeenCalledTimes(4)
    wrapper.unmount()
  })
})

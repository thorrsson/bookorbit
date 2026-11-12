import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import PasswordResetSettings from '../components/PasswordResetSettings.vue'

const { apiMock } = vi.hoisted(() => ({ apiMock: vi.fn<(input: string, init?: RequestInit) => Promise<unknown>>() }))
vi.mock('@/lib/api', () => ({ api: apiMock, NetworkError: class extends Error {} }))

beforeEach(() => {
  vi.resetAllMocks()
  apiMock.mockResolvedValue({ ok: true, json: async () => ({ lifetimeMinutes: 60 }) })
})

describe('PasswordResetSettings', () => {
  it('loads the lifetime and saves a numeric request matching the backend DTO', async () => {
    const wrapper = mount(PasswordResetSettings)
    await flushPromises()
    expect((wrapper.get('input').element as HTMLInputElement).value).toBe('60')
    await wrapper.get('input').setValue('1440')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(apiMock).toHaveBeenLastCalledWith('/api/v1/app-settings/password-reset', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ lifetimeMinutes: 1440 }),
    })
    expect(wrapper.get('[role="status"]').text()).toContain('Password reset lifetime saved')
    wrapper.unmount()
  })

  it.each(['', '0', '1441', '1.5'])('does not save invalid input %s', async (value) => {
    const wrapper = mount(PasswordResetSettings)
    await flushPromises()
    await wrapper.get('input').setValue(value)
    await wrapper.get('form').trigger('submit')
    expect(apiMock).toHaveBeenCalledTimes(1)
    expect(wrapper.get('button').attributes('disabled')).toBeDefined()
    wrapper.unmount()
  })

  it('reports load failures and prevents saving an unloaded default', async () => {
    apiMock.mockResolvedValue({ ok: false, status: 500, json: async () => ({}) })
    const wrapper = mount(PasswordResetSettings)
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toContain('Failed to load')
    expect(wrapper.get('button').attributes('disabled')).toBeDefined()
    wrapper.unmount()
  })

  it('reports save failures without discarding the entered lifetime', async () => {
    const wrapper = mount(PasswordResetSettings)
    await flushPromises()
    apiMock.mockResolvedValue({ ok: false, status: 500, json: async () => ({}) })
    await wrapper.get('input').setValue('120')
    await wrapper.get('form').trigger('submit')
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toContain('Failed to save')
    expect((wrapper.get('input').element as HTMLInputElement).value).toBe('120')
    wrapper.unmount()
  })
})

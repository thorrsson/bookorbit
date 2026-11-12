import { computed, ref } from 'vue'
import { DEFAULT_PASSWORD_RESET_LIFETIME_MINUTES, MAX_PASSWORD_RESET_LIFETIME_MINUTES, type PasswordResetSettings } from '@bookorbit/types'
import { apiJson, errorMessage, jsonBody } from '@/lib/api-json'

const MESSAGE_KEY = 'adminFeature.usersPage.passwordReset'

export function usePasswordResetSettings() {
  const lifetimeMinutes = ref<number | string>(DEFAULT_PASSWORD_RESET_LIFETIME_MINUTES)
  const loaded = ref(false)
  const saving = ref(false)
  const saved = ref(false)
  const error = ref<string | null>(null)
  const valid = computed(
    () =>
      Number.isInteger(lifetimeMinutes.value) &&
      Number(lifetimeMinutes.value) >= 1 &&
      Number(lifetimeMinutes.value) <= MAX_PASSWORD_RESET_LIFETIME_MINUTES,
  )

  async function load() {
    error.value = null
    try {
      const settings = await apiJson<PasswordResetSettings>('/api/v1/app-settings/password-reset', undefined, `${MESSAGE_KEY}.loadError`)
      lifetimeMinutes.value = settings.lifetimeMinutes
      loaded.value = true
    } catch (reason) {
      error.value = errorMessage(reason, `${MESSAGE_KEY}.loadError`)
    }
  }

  async function save() {
    if (!valid.value || !loaded.value || saving.value) return
    saving.value = true
    saved.value = false
    error.value = null
    try {
      const settings = await apiJson<PasswordResetSettings>(
        '/api/v1/app-settings/password-reset',
        jsonBody('PUT', { lifetimeMinutes: lifetimeMinutes.value }),
        `${MESSAGE_KEY}.saveError`,
      )
      lifetimeMinutes.value = settings.lifetimeMinutes
      saved.value = true
    } catch (reason) {
      error.value = errorMessage(reason, `${MESSAGE_KEY}.saveError`)
    } finally {
      saving.value = false
    }
  }

  return { lifetimeMinutes, loaded, saving, saved, error, valid, load, save }
}

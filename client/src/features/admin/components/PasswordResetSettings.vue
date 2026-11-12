<script setup lang="ts">
import { onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { MAX_PASSWORD_RESET_LIFETIME_MINUTES } from '@bookorbit/types'
import { Button } from '@/components/ui/button'
import { usePasswordResetSettings } from '../composables/usePasswordResetSettings'

const { t } = useI18n()
const { lifetimeMinutes, loaded, saving, saved, error, valid, load, save } = usePasswordResetSettings()
onMounted(load)
</script>

<template>
  <form class="settings-card mt-5" @submit.prevent="save">
    <div class="settings-row">
      <div class="min-w-0">
        <label for="password-reset-lifetime" class="settings-label">{{ t('adminFeature.usersPage.passwordReset.label') }}</label>
        <p id="password-reset-lifetime-hint" class="settings-hint settings-prose">{{ t('adminFeature.usersPage.passwordReset.hint') }}</p>
      </div>
      <div class="flex w-full items-center gap-2 md:w-auto">
        <input
          id="password-reset-lifetime"
          v-model.number="lifetimeMinutes"
          type="number"
          min="1"
          :max="MAX_PASSWORD_RESET_LIFETIME_MINUTES"
          step="1"
          required
          :disabled="!loaded || saving"
          aria-describedby="password-reset-lifetime-hint"
          class="input-field w-28"
        />
        <Button type="submit" variant="outline" :disabled="!loaded || saving || !valid">{{ t('common.save') }}</Button>
      </div>
    </div>
    <p v-if="error" role="alert" class="settings-error-state">{{ error }}</p>
    <p v-if="saved" role="status" class="settings-hint">{{ t('adminFeature.usersPage.passwordReset.saved') }}</p>
  </form>
</template>

/// <reference types="vite/client" />

import 'vue-router'
import type { Permission } from '@bookorbit/types'
import type { RouteLocationNormalizedLoaded } from 'vue-router'

declare global {
  /** UTC build date (YYYY-MM-DD), shown as the modification date required by ADDITIONAL_TERMS.md. */
  const __BUILD_DATE__: string
}

declare module 'vue-router' {
  interface RouteMeta {
    public?: boolean
    requiredPermission?: Permission
    forbiddenPermission?: Permission
    permissionFallback?: string
    maxWidth?: string
    title?: string | ((to: RouteLocationNormalizedLoaded) => string)
    /** The view opens with a PageTitleRow, which carries the phone menu and search buttons itself. */
    titleRow?: boolean
  }
}

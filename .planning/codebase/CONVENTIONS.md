# Coding Conventions

**Analysis Date:** 2025-02-24

## Naming Patterns

**Files:**
- React components: PascalCase with `.tsx` extension
  - Example: `QueryWorkspace.tsx`, `AddConnectionDialog.tsx`
- Custom hooks: camelCase with `use` prefix, `.ts` extension
  - Example: `useTheme.ts`, `useKeyboardShortcuts.ts`
- Store files: camelCase with `Store` suffix, `.ts` extension
  - Example: `connectionStore.ts`, `editorStore.ts`
- Utility files: camelCase, `.ts` extension
  - Example: `cn.ts` (tailwind merge utility), `tauri.ts` (command wrappers)
- Directories: kebab-case (multi-word), all lowercase
  - Example: `src/components/layout/`, `src/components/editor/`, `src/components/dialogs/`

**Functions:**
- React components: PascalCase
  - Example: `function QueryWorkspace() {}`, `function AddConnectionDialog() {}`
- Regular functions (utilities, callbacks): camelCase
  - Example: `buildConnectionString()`, `formatCellValue()`, `extractTableName()`
- Handler functions: camelCase with `handle` prefix
  - Example: `handleChange()`, `handleTest()`, `handleSchemaRefresh()`
- Getter functions in stores: camelCase with `get` prefix
  - Example: `getConnection()`, `getActiveConnection()`, `getConnectedConnections()`

**Variables:**
- Local state: camelCase
  - Example: `const [isOpen, setIsOpen] = useState(false)`
- Constants: UPPER_SNAKE_CASE (only for true constants)
  - Example: `const CONNECTION_COLORS = []`, `const MIN_COLUMN_WIDTH = 60`
- Store selectors: camelCase
  - Example: `const activeConnection = useConnectionStore((state) => state.getActiveConnection())`
- DOM element refs: camelCase with `Ref` suffix
  - Example: `const queryEditorRef = useRef<QueryEditorRef>(null)`

**Types:**
- Interfaces: PascalCase with descriptive nouns
  - Example: `ConnectionConfig`, `QueryTab`, `ValidationState`, `ResultsGridProps`
- Type aliases: PascalCase
  - Example: `type SslMode = 'disable' | 'prefer' | 'require'`
- Union types: Descriptive string values in quotes
  - Example: `type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error'`

## Code Style

**Formatting:**
- Tool: Not explicitly configured (relies on TypeScript compiler and IDE defaults)
- No `.prettierrc` or `.eslintrc` in project
- Line length: No explicit limit enforced
- Indentation: 2 spaces (inferred from Tailwind config and store examples)
- Quotes: Single quotes for strings
  - Example: `const name = 'QueryWorkspace'`
- Semicolons: Always present
  - Example: `return invoke('execute_query', { connectionId, sql });`

**Linting:**
- TypeScript strict mode enabled in `tsconfig.json`
  - `strict: true`
  - `noUnusedLocals: true`
  - `noUnusedParameters: true`
  - `noFallthroughCasesInSwitch: true`
- No external linter (ESLint, Prettier) configured
- Type checking via `tsc --noEmit`

## Import Organization

**Order:**
1. React core imports
   - `import React from 'react'`
   - `import { useState, useEffect } from 'react'`
2. External libraries (with @ scope packages grouped separately)
   - `import { invoke } from '@tauri-apps/api/core'`
   - `import { cn } from '@/lib/cn'`
   - `import clsx from 'clsx'`
3. Local imports from `@/` (aliased paths)
   - `import { useConnectionStore } from '@/stores/connectionStore'`
   - `import { QueryWorkspace } from '@/components/layout/QueryWorkspace'`
   - `import type { Connection } from '@/lib/types'`
4. Type imports (always using `type` keyword)
   - `import type { ConnectionConfig, ConnectionStatus } from '@/lib/types'`
   - Type imports separated with blank line before runtime imports

**Path Aliases:**
- Alias: `@/` → `src/`
- Configured in `vite.config.ts` and `tsconfig.json`
- Always use aliases for local imports, never relative paths
  - Correct: `import { cn } from '@/lib/cn'`
  - Wrong: `import { cn } from '../lib/cn'`

## Error Handling

**Patterns:**
- Promise-based error handling with `.catch()`
  - Example: `tauri.loadConnections().catch((err) => { console.error('Failed to load connections:', err); })`
- Try-catch blocks in async functions
  - Example: `try { const result = await tauri.executeQuery(...) } catch (err) { setTabError(err instanceof Error ? err.message : String(err)); }`
- Type guard for Error objects
  - Pattern: `err instanceof Error ? err.message : String(err)`
  - Used consistently to safely extract error messages
- Fire-and-forget patterns for non-critical operations with `.catch(console.error)`
  - Example: `tauri.checkQueryEditable(...).catch((err) => { console.error('Editability check failed:', err); })`
- Console logging for errors
  - Example: `console.error('Failed to load connections:', err)`

**Error State Management:**
- Errors stored in Zustand stores with dedicated error fields
  - Example: `error: ValidationError | null` in `ValidationState`
  - Example: `error?: string` in `Connection` interface
- UI components track execution state alongside errors
  - Example: `isExecuting: boolean` with `error: string | null` in same state object
- Validation errors have detailed structure (message, position, line, column)
  - Example: `ValidationError` interface in `src/stores/editorStore.ts`

## Logging

**Framework:** console methods (built-in)

**Patterns:**
- Error logging: `console.error('User-friendly message:', err)`
  - Example: `console.error('Failed to load connections:', err)`
  - Example: `console.error('Editability check failed:', err)`
- Used for non-critical failures and debugging
- No info/warn/debug logging in codebase
- Fire-and-forget operations log errors but don't propagate them
  - Example: `tauri.checkQueryEditable(...).catch((err) => { console.error(...) })`

## Comments

**When to Comment:**
- JSDoc for exported functions and utilities (some examples present)
- Inline comments for non-obvious logic or workarounds
  - Example: `// Fire-and-forget editability check for non-EXPLAIN queries` in `QueryWorkspace.tsx`
  - Example: `// Normalize whitespace and remove comments` in `editorStore.ts`
- Section comments for multi-step operations
  - Example: `// Sync local state when settings are loaded from disk`
- Comments explaining why code is structured a certain way, not what it does

**JSDoc/TSDoc:**
- Used selectively, not consistently
- Example from `src/components/editor/QueryEditor.tsx`:
  ```typescript
  /**
   * Map our shortcut key strings to Monaco KeyCode values
   */
  function getMonacoKeyCode(key: string, monaco: typeof import('monaco-editor')): KeyCode | null {
  ```
- Interface properties sometimes documented, not consistently applied

## Function Design

**Size:**
- Small, focused functions (typical range: 10-50 lines)
- Extracted handlers into separate `useCallback` hooks
- Helper functions extracted to module level for reuse
  - Example: `formatDuration()`, `formatCellValue()` in `ResultsGrid.tsx`
  - Example: `extractTableName()` in `editorStore.ts`

**Parameters:**
- Destructured from objects when multiple related parameters
  - Example: `{ isOpen, onClose }: AddConnectionDialogProps`
- Named parameters over positional (especially in Tauri command wrappers)
  - Example: `async function executeQuery(connectionId: string, sql: string, queryId?: string, limit?: number, schema?: string | null)`
- Type parameters used for complex generic functions
  - Example: `create<ConnectionState>((set, get) => ({...}))` in Zustand stores

**Return Values:**
- Explicit return types for all exported functions
  - Example: `export function cn(...inputs: ClassValue[]): string`
  - Example: `export async function executeQuery(...): Promise<QueryResult>`
- Implicit return for short arrow functions
  - Example: `const getActiveConnection = () => get().connections[activeConnectionId]`
- Nullable returns with explicit `| null` or `| undefined`
  - Example: `function extractTableName(sql: string): string | null`

## Module Design

**Exports:**
- Named exports for utilities and components
  - Example: `export function useTheme() {}`
  - Example: `export function cn(...inputs: ClassValue[]) {}`
- Default exports for React components
  - Example: `export default App`
- Type exports for all types
  - Example: `export interface ConnectionConfig {}`
  - Example: `export type SslMode = 'disable' | 'prefer' | 'require'`

**Barrel Files:**
- Not used (no index.ts files in component directories)
- Each import specifies exact file path
  - Example: `import { QueryWorkspace } from '@/components/layout/QueryWorkspace'`
  - Example: `import { useTheme } from '@/hooks/useTheme'`

**Store Pattern (Zustand):**
- Interface defining full state shape, then create hook
  - Example: `interface ConnectionState { ... }` followed by `export const useConnectionStore = create<ConnectionState>(...)`
- Actions and getters grouped in interface
- State slice defined inline in `create()` call
- Immutable updates via spread operators
  - Example: `{ ...state.connections, [config.id]: newConnection }`
  - Example: `[...state.connectionOrder, config.id]`

**Tauri Command Wrappers:**
- One function per command in `src/lib/tauri.ts`
- Functions wrap `invoke()` calls with type-safe parameters and return types
- Organized by domain (connection commands, schema commands, query commands, etc.)
- Sanitization of numeric values before sending to Rust
  - Example: `Math.round()` for settings values in `saveSettings()`

## Constants and Configuration

**Theme Colors:**
- CSS variable names: `--bg-primary`, `--text-secondary`, `--border-primary`
  - Defined in `src/index.css` with dark and light theme variants
- Tailwind theme colors extended with theme variables
  - Accessed via `className="bg-theme-bg-primary"`
- Color palettes defined as arrays in components
  - Example: `CONNECTION_COLORS` array in `AddConnectionDialog.tsx`

**Default Values:**
- Grouped in types file: `DEFAULT_SETTINGS` and `DEFAULT_SHORTCUTS` in `src/lib/types.ts`
- Store defaults defined in store creation
  - Example: `connectionOrder: []` in `useConnectionStore`
- Component defaults as local constants with naming pattern
  - Example: `const DEFAULT_SPLIT_POSITION = 40` in `QueryWorkspace.tsx`

## React Patterns

**State Management:**
- Zustand stores for global state (connections, editor tabs, saved queries, settings, query history)
- Local useState for component-level UI state
- Selector pattern for Zustand subscriptions
  - Example: `const activeConnection = useConnectionStore((state) => state.getActiveConnection())`
- Minimize selector complexity by calling getter functions
  - Example: `state.getActiveConnection()` instead of computing in selector

**Component Props:**
- Props interfaces named `{ComponentName}Props`
- Destructured in function signature
- Optional props marked with `?`
- Ref forwarding when needed
  - Example: `export const QueryEditor = forwardRef<QueryEditorRef, QueryEditorProps>(...)`

**Hooks:**
- Custom hooks in `src/hooks/` directory
- Use pattern: custom hooks isolate side-side effects and state logic
  - Example: `useTheme()` manages theme synchronization
  - Example: `useKeyboardShortcuts()` handles keyboard event registration
- Use `useCallback` for memoized handlers passed as props
- Use `useRef` for stable DOM/editor references

**Effects:**
- `useEffect` dependencies fully declared
  - Example: `[theme, getEffectiveTheme]` in `useTheme`
  - Example: `[activeTab, activeConnection, activeConnectionId, ...]` in `QueryWorkspace`
- Cleanup functions returned when setting up listeners
  - Example: Returning `() => mediaQuery.removeEventListener(...)` in `useTheme`

---

*Convention analysis: 2025-02-24*

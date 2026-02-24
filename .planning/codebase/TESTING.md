# Testing Patterns

**Analysis Date:** 2025-02-24

## Test Framework

**Runner:** Not configured

**Assertion Library:** Not configured

**Current State:**
- No test framework installed (Jest, Vitest, etc.)
- No test files found in codebase (*.test.*, *.spec.*)
- No test configuration files (`jest.config.ts`, `vitest.config.ts`)
- No test runner npm scripts (no `test` or `test:watch` commands in `package.json`)

**Run Commands:**
```bash
# Not available - testing infrastructure not set up
```

## Test File Organization

**Status:** Not Applicable

Testing infrastructure is not currently established in the project. No existing test files, runners, or configuration.

## Test Structure

Testing has not been implemented in this codebase.

## Mocking

**Framework:** Not applicable

## Fixtures and Factories

**Test Data:** Not applicable

## Coverage

**Requirements:** Not enforced

## Test Types

**Unit Tests:**
- Not implemented

**Integration Tests:**
- Not implemented

**E2E Tests:**
- Not implemented

## Manual Testing Approaches

While no automated tests exist, the codebase includes patterns that facilitate manual testing:

**Error State Testing:**
- Zustand stores track error states alongside execution states
  - Example: `ValidationState` includes `error: ValidationError | null`
  - Example: `Connection` interface includes `error?: string`
- UI components display these error states with user-visible messages
  - Example: `QueryWorkspace` shows execution errors via `setTabError()`

**State Validation:**
- Type safety via strict TypeScript (`strict: true` in `tsconfig.json`)
- Runtime type guards for error handling
  - Pattern: `err instanceof Error ? err.message : String(err)`
- Nullable field handling with explicit `| null` types
  - Example: `error?: string` in various state interfaces

**Tauri Command Wrappers:**
- Centralized in `src/lib/tauri.ts` for testability
- All Rust-Frontend communication goes through typed wrapper functions
- Enables potential future mocking by replacing command implementations
- Type-safe parameter and return value contracts

**Component Props Contracts:**
- Props interfaces define expected inputs and callbacks
  - Example: `ResultsGridProps` with callbacks like `onLoadMore?`, `onExport?`
- Clear separation between required and optional props
- Ref forwarding for imperative operations
  - Example: `ResultsGridRef` with `copyToClipboard()` method

**Store Design for Testability:**
- Pure reducer functions in Zustand store actions
  - Example: immutable updates via spread operators in `connectionStore.ts`
- Getter functions separated from state mutations
  - Example: `getActiveConnection()` vs `setActiveConnection()`
- Selective state selectors in components minimize coupling
  - Example: Components select only needed fields, not entire state

## Implementation Recommendations

When adding testing to this project:

**1. Test Framework Setup**
- Recommend Vitest (faster, TypeScript-first, works with Vite)
- Add to `devDependencies` in `package.json`
- Create `vitest.config.ts` at project root
- Add test scripts: `"test": "vitest"`, `"test:ui": "vitest --ui"`

**2. Test File Location**
- Co-locate tests with implementation files
  - Example: `src/stores/connectionStore.ts` → `src/stores/connectionStore.test.ts`
  - Example: `src/lib/tauri.ts` → `src/lib/tauri.test.ts`
- Alternative: `__tests__` directory at same level
  - Example: `src/stores/__tests__/connectionStore.test.ts`

**3. Test Organization by Type**

**Store Tests:**
```typescript
// Test Zustand store actions and getters
describe('connectionStore', () => {
  it('should add a new connection', () => {
    // Test immutable state updates
  });

  it('should get active connection', () => {
    // Test getter functions
  });
});
```

**Hook Tests:**
```typescript
// Use @testing-library/react-hooks
describe('useTheme', () => {
  it('should apply theme to document element', () => {
    // Test effect side effects
  });
});
```

**Component Tests:**
```typescript
// Use @testing-library/react
describe('QueryWorkspace', () => {
  it('should render tabs', () => {
    // Test rendering with mocked stores
  });

  it('should execute query on button click', () => {
    // Test callbacks and Tauri invocations
  });
});
```

**4. Mocking Strategy**

**Zustand Stores:**
- Mock using jest/vi mocking
  ```typescript
  vi.mock('@/stores/connectionStore', () => ({
    useConnectionStore: vi.fn((selector) => selector({
      activeConnectionId: 'test-id',
      getActiveConnection: () => mockConnection,
    })),
  }));
  ```

**Tauri Commands:**
- Mock `invoke` function in `@tauri-apps/api/core`
  ```typescript
  vi.mock('@tauri-apps/api/core', () => ({
    invoke: vi.fn(),
  }));
  ```
- Mock response types based on `src/lib/tauri.ts` type signatures

**External Dependencies:**
- Mock Monaco Editor for editor component tests
- Mock TanStack Virtual for virtualized grid tests

**5. Coverage Targets**

Recommended targets per type:
- **Stores:** 90%+ (pure functions, easy to test)
- **Hooks:** 80%+ (with side effects, sometimes harder to test)
- **Components:** 70%+ (requires mocking stores and Tauri)
- **Utils:** 95%+ (pure functions, exhaustive testing)

**6. Test Patterns for This Codebase**

**Immutability Testing:**
```typescript
// Verify Zustand store updates don't mutate original state
it('should not mutate existing state', () => {
  const originalState = { ...state };
  store.getState().addConnection(newConfig);
  expect(originalState.connections).toEqual(store.getState().connections before);
});
```

**Error Handling:**
```typescript
// Test error state management
it('should set error on failed query', () => {
  // Simulate query execution failure
  // Verify setTabError was called with message
});
```

**Async Operations:**
```typescript
// Test Promise-based operations
it('should handle async Tauri commands', async () => {
  const spy = vi.spyOn(tauri, 'executeQuery').mockResolvedValueOnce(result);
  // Trigger execution
  await waitFor(() => expect(spy).toHaveBeenCalled());
});
```

---

*Testing analysis: 2025-02-24*

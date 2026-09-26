import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ execCli: vi.fn() }))

vi.mock('@/lib/cli-exec', () => ({ execCli: mocks.execCli }))

import { codexPrompt } from '@/lib/codex-cli'

describe('Codex CLI error handling', () => {
  beforeEach(() => vi.clearAllMocks())

  it('failed command arguments never escape through the error result', async () => {
    mocks.execCli.mockRejectedValue(new Error('Command failed with PRIVATE_BOOKMARK_TEXT'))

    const result = await codexPrompt('PRIVATE_BOOKMARK_TEXT', { model: 'gpt-6-luna' })

    expect(result).toEqual({ success: false, error: 'Codex CLI request failed' })
    expect(JSON.stringify(result)).not.toContain('PRIVATE_BOOKMARK_TEXT')
  })
})

import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  codexPrompt: vi.fn(),
  feedbackFindMany: vi.fn(),
  getActiveAuthMode: vi.fn(),
  getActiveCliModel: vi.fn(),
  getActiveModel: vi.fn(),
  getProvider: vi.fn(),
}))

vi.mock('@/lib/db', () => ({ default: { categoryFeedback: { findMany: mocks.feedbackFindMany } } }))
vi.mock('@/lib/codex-cli', () => ({ codexPrompt: mocks.codexPrompt }))
vi.mock('@/lib/settings', () => ({
  getActiveAuthMode: mocks.getActiveAuthMode,
  getActiveCliModel: mocks.getActiveCliModel,
  getActiveModel: mocks.getActiveModel,
  getProvider: mocks.getProvider,
}))
vi.mock('@/lib/claude-cli-auth', () => ({
  claudePrompt: vi.fn(),
  getCliAvailability: vi.fn().mockResolvedValue(false),
  modelNameToCliAlias: vi.fn(),
}))
vi.mock('@/lib/ai-client', () => ({ resolveAIClient: vi.fn() }))
vi.mock('@/lib/jev-categorizer', () => ({ categorizeWithJev: vi.fn() }))

import { categorizeBatch } from '@/lib/categorizer'

describe('Lunaの部分応答', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.feedbackFindMany.mockResolvedValue([])
    mocks.getActiveAuthMode.mockResolvedValue('cli')
    mocks.getActiveCliModel.mockResolvedValue('gpt-5.6-luna')
    mocks.getProvider.mockResolvedValue('openai')
  })

  it('返された結果を保持し、欠落IDだけ5件以下で再試行する', async () => {
    mocks.codexPrompt
      .mockResolvedValueOnce({
        success: true,
        data: `\`\`\`json\n${JSON.stringify([{ tweetId: 'tweet-1', assignments: [{ category: 'dev-tools', confidence: 0.9 }] }])}\n\`\`\``,
      })
      .mockResolvedValueOnce({
        success: true,
        data: JSON.stringify(['tweet-2', 'tweet-3', 'tweet-4', 'tweet-5', 'tweet-6'].map((tweetId) => ({
          tweetId,
          assignments: [{ category: 'dev-tools', confidence: 0.8 }],
        }))),
      })
      .mockResolvedValueOnce({
        success: true,
        data: JSON.stringify([{ tweetId: 'tweet-7', assignments: [{ category: 'dev-tools', confidence: 0.8 }] }]),
      })

    const bookmarks = Array.from({ length: 7 }, (_, index) => ({
      tweetId: `tweet-${index + 1}`,
      text: `Bookmark ${index + 1}`,
    }))
    const results = await categorizeBatch(bookmarks, null, { 'dev-tools': 'Development tools' }, ['dev-tools'])

    expect(results.map((result) => result.tweetId)).toEqual(bookmarks.map((bookmark) => bookmark.tweetId))
    expect(mocks.codexPrompt).toHaveBeenCalledTimes(3)
    expect(mocks.codexPrompt.mock.calls[1][0]).toContain('tweet-2')
    expect(mocks.codexPrompt.mock.calls[1][0]).toContain('tweet-6')
    expect(mocks.codexPrompt.mock.calls[1][0]).not.toContain('tweet-1')
    expect(mocks.codexPrompt.mock.calls[2][0]).toContain('tweet-7')
    expect(mocks.codexPrompt.mock.calls[2][0]).not.toContain('tweet-6')
    expect(mocks.codexPrompt.mock.calls[2][1]).toMatchObject({ reasoningEffort: 'xhigh' })
  })
})

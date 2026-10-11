import { describe, expect, it } from "vitest";
import { matchWhitelistEndpoint, normalizeWhitelistRequestPath } from "../routes/whitelist.js";

/**
 * AGENT_PREFIX_RE and server.ts's route table are two lists that must stay in sync by hand.
 * These tests pin the invariant in both directions so a newly routed agent cannot silently
 * lose its auxiliary endpoints (see #1246): the primary handlers mask a whitelist miss with a
 * `?? "/messages"` fallback, while the auxiliary runner answers 404 "Unregistered endpoint".
 */

/** Agent path prefixes that `server.ts` registers routes for. */
const ROUTED_AGENTS = [
  "claude-code",
  "codebuddy",
  "codex",
  "cursor",
  "anthropic",
  "openai",
  "pi",
  "dsh",
];

describe("whitelist normalization covers every routed agent prefix", () => {
  for (const agent of ROUTED_AGENTS) {
    it(`strips /${agent}/<spaceId> so /v1/messages matches the whitelist`, () => {
      const path = `/${agent}/team-abc/v1/messages`;
      expect(normalizeWhitelistRequestPath(path)).toBe("/v1/messages");
      expect(matchWhitelistEndpoint(path)?.upstreamEndpoint).toBe("/messages");
    });
  }

  it("resolves dsh auxiliary endpoints (regression for #1246)", () => {
    expect(matchWhitelistEndpoint("/dsh/team-abc/v1/messages/count_tokens")?.upstreamEndpoint).toBe(
      "/messages/count_tokens",
    );
    expect(matchWhitelistEndpoint("/dsh/team-abc/v1/embeddings")?.upstreamEndpoint).toBe("/embeddings");
  });
});

describe("whitelist normalization does not over-strip", () => {
  /**
   * Tripwire for the opposite mistake: widening AGENT_PREFIX_RE to "any first path segment"
   * would make every assertion above pass while silently mis-routing unknown prefixes.
   * workbuddy is a routed agent that registers no anthropic aux endpoints, so it must stay null.
   */
  it("leaves an unknown prefix unmatched instead of stripping it", () => {
    expect(matchWhitelistEndpoint("/not-an-agent/team-abc/v1/messages")).toBeNull();
  });

  it("leaves workbuddy unmatched until its routes exist", () => {
    expect(matchWhitelistEndpoint("/workbuddy/team-abc/v1/messages/count_tokens")).toBeNull();
  });
});

import { afterEach, describe, expect, it, vi } from "vitest";

import { customFetch } from "./mutator";

describe("customFetch", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("forwards the caller abort signal to fetch", async () => {
    vi.stubEnv("NEXT_PUBLIC_API_URL", "https://api.example.com");
    const abortController = new AbortController();
    const fetchMock = vi.fn(async () => {
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    await customFetch("/api/v1/boards", {
      method: "GET",
      signal: abortController.signal,
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.example.com/api/v1/boards",
      expect.objectContaining({
        signal: abortController.signal,
      }),
    );
  });
});

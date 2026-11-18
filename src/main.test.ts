import { describe, expect, it } from "vitest";

import { greeting } from "./main";

describe("greeting", () => {
  it("greeting_returns_the_starter_text", () => {
    expect(greeting()).toBe("Hello from the Node/Vite starter!");
  });
});

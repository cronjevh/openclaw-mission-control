/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: ["class"],
  content: ["./src/**/*.{ts,tsx}", "./app/**/*.{ts,tsx}"],
  theme: {
    extend: {
      fontFamily: {
        heading: ["var(--font-heading)", "sans-serif"],
        body: ["var(--font-body)", "sans-serif"],
        display: ["var(--font-display)", "serif"],
      },
      colors: {
        // Wire Tailwind color names to our CSS variables so
        // bg-popover, text-foreground, bg-accent etc. all just work.
        background:    "var(--bg)",
        foreground:    "var(--text)",
        surface:       "var(--surface)",
        "surface-muted":  "var(--surface-muted)",
        "surface-strong": "var(--surface-strong)",
        border:        "var(--border)",
        "border-strong": "var(--border-strong)",
        input:         "var(--border)",
        ring:          "var(--accent)",
        card: {
          DEFAULT:     "var(--surface)",
          foreground:  "var(--text)",
        },
        popover: {
          DEFAULT:     "var(--surface)",
          foreground:  "var(--text)",
        },
        primary: {
          DEFAULT:     "var(--accent)",
          foreground:  "var(--accent-text)",
        },
        secondary: {
          DEFAULT:     "var(--surface-muted)",
          foreground:  "var(--text)",
        },
        muted: {
          DEFAULT:     "var(--surface-muted)",
          foreground:  "var(--text-muted)",
        },
        accent: {
          DEFAULT:     "var(--surface-strong)",
          foreground:  "var(--text)",
        },
        destructive: {
          DEFAULT:     "var(--danger)",
          foreground:  "var(--text-inverse)",
        },
      },
    },
  },
  plugins: [require("tailwindcss-animate"), require("@tailwindcss/typography")],
};

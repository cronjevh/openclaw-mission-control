"use client";

import { SignUp } from "@clerk/nextjs";

export default function SignUpPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-50 p-6">
      <SignUp
        routing="path"
        path="/sign-up"
        forceRedirectUrl="/boards"
      />
    </main>
  );
}

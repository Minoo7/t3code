const RETRY_KEY = "t3code:dev-boot-retries";
const MAX_RETRIES = 3;

export function retryFailedDesktopDevImport(error: unknown): boolean {
  if (
    !import.meta.env.DEV ||
    window.location.protocol !== "t3code-dev:" ||
    !(error instanceof Error) ||
    !error.message.includes("Failed to fetch dynamically imported module")
  ) {
    return false;
  }

  try {
    const retries = Number(window.sessionStorage.getItem(RETRY_KEY) ?? "0");
    if (!Number.isInteger(retries) || retries < 0 || retries >= MAX_RETRIES) {
      return false;
    }
    window.sessionStorage.setItem(RETRY_KEY, String(retries + 1));
    window.setTimeout(() => window.location.reload(), 4_000 * (retries + 1));
    return true;
  } catch {
    return false;
  }
}

export function clearDesktopDevImportRetries(): void {
  try {
    window.sessionStorage.removeItem(RETRY_KEY);
  } catch {
    // The page still loaded successfully when session storage is unavailable.
  }
}

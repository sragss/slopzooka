import { ServiceError } from "./errors.js";

export function normalizedName(value: unknown): string {
  if (typeof value !== "string")
    throw new ServiceError("A name is required", 400);
  const name = value.trim().replace(/\s+/gu, "-");
  if (!name || name.length > 120 || /[\x00-\x1f]/u.test(name))
    throw new ServiceError("Names must be 1–120 characters", 400);
  return name;
}

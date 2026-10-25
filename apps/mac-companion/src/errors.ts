/** A user-facing error with an HTTP status; shared by the host's domain services. */
export class ServiceError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
  ) {
    super(message);
    this.name = "ServiceError";
  }
}

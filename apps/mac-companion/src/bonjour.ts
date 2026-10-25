import { Bonjour } from "bonjour-service";

import type { Logger } from "./logger.js";

export const SLOPZOOKA_BONJOUR_TYPE = "slopzooka";

type BonjourAdvertiserOptions = {
  logger: Logger;
  name: string;
  port: number;
  hostId: string;
};

export type BonjourAdvertiser = {
  stop: () => Promise<void>;
};

export function startBonjourAdvertiser(
  options: BonjourAdvertiserOptions,
): BonjourAdvertiser {
  const bonjour = new Bonjour();
  const service = bonjour.publish({
    name: options.name,
    type: SLOPZOOKA_BONJOUR_TYPE,
    protocol: "tcp",
    port: options.port,
    txt: {
      name: "SlopZooka",
      version: "0.2.0",
      hostId: options.hostId,
    },
  });

  service.on("up", () => {
    options.logger.info("Bonjour service advertised", {
      serviceType: `_${SLOPZOOKA_BONJOUR_TYPE}._tcp`,
      serviceName: options.name,
      port: options.port,
    });
  });

  service.on("error", (error) => {
    options.logger.error("Bonjour service error", {
      error: error instanceof Error ? error.message : String(error),
    });
  });

  return {
    stop: () =>
      new Promise((resolve) => {
        const stopService = service.stop?.bind(service);
        if (!stopService) {
          bonjour.destroy();
          options.logger.info("Bonjour service stopped", {
            serviceName: options.name,
          });
          resolve();
          return;
        }

        stopService(() => {
          bonjour.destroy();
          options.logger.info("Bonjour service stopped", {
            serviceName: options.name,
          });
          resolve();
        });
      }),
  };
}

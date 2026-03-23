import { Bonjour } from "bonjour-service";

import type { Logger } from "./logger.js";

export const SLOPZOOKA_BONJOUR_TYPE = "slopzooka";

type BonjourAdvertiserOptions = {
  logger: Logger;
  name: string;
  host: string;
  port: number;
};

export type BonjourAdvertiser = {
  stop: () => Promise<void>;
};

export function startBonjourAdvertiser(options: BonjourAdvertiserOptions): BonjourAdvertiser {
  const bonjour = new Bonjour();
  const service = bonjour.publish({
    name: options.name,
    type: SLOPZOOKA_BONJOUR_TYPE,
    protocol: "tcp",
    host: options.host,
    port: options.port,
    txt: {
      name: "SlopZooka",
      version: "0.1.0"
    }
  });

  service.on("up", () => {
    options.logger.info("Bonjour service advertised", {
      serviceType: `_${SLOPZOOKA_BONJOUR_TYPE}._tcp`,
      serviceName: options.name,
      host: options.host,
      port: options.port
    });
  });

  service.on("error", (error) => {
    options.logger.error("Bonjour service error", {
      error: error instanceof Error ? error.message : String(error)
    });
  });

  return {
    stop: () =>
      new Promise((resolve) => {
        const stopService = service.stop?.bind(service);
        if (!stopService) {
          bonjour.destroy();
          options.logger.info("Bonjour service stopped", {
            serviceName: options.name
          });
          resolve();
          return;
        }

        stopService(() => {
          bonjour.destroy();
          options.logger.info("Bonjour service stopped", {
            serviceName: options.name
          });
          resolve();
        });
      })
  };
}

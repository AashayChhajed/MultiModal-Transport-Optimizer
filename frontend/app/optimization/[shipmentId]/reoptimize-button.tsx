"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { optimizeShipment, type OptimizationType } from "@/lib/api";

/**
 * Re-runs the optimization for a result that is already stored.
 *
 * The results page is a server component and used to be read-only, so a stored
 * row could never be regenerated from the browser - for example one computed
 * while the ML service was unavailable kept reporting a missing ETA forever.
 *
 * The backend does not persist the optimization goal with the result, so this
 * falls back to CHEAPEST, the same default the create-shipment flow uses.
 */
export function ReoptimizeButton({
  shipmentId,
  optimizationType,
}: {
  shipmentId: number;
  optimizationType: OptimizationType | null;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const goal: OptimizationType = optimizationType ?? "CHEAPEST";

  const rerun = () => {
    setError(null);
    startTransition(async () => {
      try {
        await optimizeShipment(shipmentId, goal);
        // Re-render the server component so the fresh row (including the ML
        // ETA) is picked up without a full page reload.
        router.refresh();
      } catch (e) {
        setError(e instanceof Error ? e.message : "Re-run failed");
      }
    });
  };

  return (
    <div className="flex flex-col items-end gap-1">
      <Button size="sm" variant="outline" onClick={rerun} disabled={pending}>
        {pending ? "Re-running..." : `Re-run optimization (${goal.toLowerCase()})`}
      </Button>
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

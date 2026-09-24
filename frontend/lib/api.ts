export type City = {
  id: number;
  name: string;
  latitude: number;
  longitude: number;
};

export type ShipmentRequest = {
  sourceCityId: number;
  destinationCityId: number;
  weight: number;
  description: string;
};

export type Shipment = {
  id: number;
  sourceCityId: number;
  sourceCityName: string;
  destinationCityId: number;
  destinationCityName: string;
  weight: number;
  description: string;
};

export type OptimizationType = "CHEAPEST" | "FASTEST";

export type OptimizationRouteStep = {
  sourceCity: string;
  destinationCity: string;
  transportMode: string;
  distance: number;
  cost: number;
  time: number;
  carbon: number;
};

export type OptimizationResult = {
  shipmentId: number;
  optimizationType: OptimizationType | null;
  totalCost: number;
  totalTime: number;
  totalDistance: number;
  totalCarbon: number;
  cities: string[];
  routes: OptimizationRouteStep[];
  predictedEtaHours: number | null;
  etaPredictionAvailable: boolean;
};

export type DashboardStats = {
  totalShipments: number;
  optimizedShipments: number;
  totalRoutes: number;
  averageCost: number;
  averageTime: number;
  totalDistance: number;
  totalCarbon: number;
};

// NEXT_PUBLIC_BACKEND_URL is the documented name (.env.local / Render dashboard).
// NEXT_PUBLIC_API_URL is kept as an alias so older setups keep working, and the
// localhost default means a missing env file can never produce `undefined/...` URLs.
const API_BASE_URL =
  process.env.NEXT_PUBLIC_BACKEND_URL ??
  process.env.NEXT_PUBLIC_API_URL ??
  "http://localhost:8080";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    cache: "no-store",
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });

  if (!response.ok) {
    let message = `Request failed with status ${response.status}`;
    try {
      const payload = await response.json();
      if (payload?.message) {
        message = payload.message;
      }
    } catch {
      // Keep generic message if response is not JSON.
    }
    throw new Error(message);
  }

  return response.json() as Promise<T>;
}

export function getCities() {
  return request<City[]>("/cities");
}

export function getShipments() {
  return request<Shipment[]>("/shipments");
}

export function createShipment(payload: ShipmentRequest) {
  return request<Shipment>("/shipments", {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export function optimizeShipment(shipmentId: number, optimizationType: OptimizationType) {
  return request<OptimizationResult>(`/shipments/${shipmentId}/optimize?optimizationType=${optimizationType}`, {
    method: "POST",
  });
}

export function getOptimizationResult(shipmentId: number) {
  return request<OptimizationResult>(`/optimization/${shipmentId}`);
}

export function getDashboardStats() {
  return request<DashboardStats>("/dashboard/stats");
}

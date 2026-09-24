package com.optimizer.backend.Service;

import com.optimizer.backend.DTO.OptimizationResponseDTO;
import com.optimizer.backend.Entity.OptimizationResult;
import com.optimizer.backend.Entity.OptimizationType;
import com.optimizer.backend.Entity.Shipment;
import com.optimizer.backend.Exception.BadRequestException;
import com.optimizer.backend.Repository.OptimizationResultRepository;
import com.optimizer.backend.graph.*;
import com.optimizer.backend.ml.EtaPredictionResponse;
import com.optimizer.backend.ml.EtaPredictionService;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class OptimizationService {

    private static final Logger log = LoggerFactory.getLogger(OptimizationService.class);

    private final TransportGraphLoader graphLoader;
    private final OptimizationResultRepository optimizationResultRepository;
    private final TransferTimeCalculator transferTimeCalculator;
    private final EtaPredictionService etaPredictionService;

    @Transactional
    public OptimizationResponseDTO optimize(Shipment shipment, OptimizationType optimizationType,
                                            PathfindingAlgorithm algorithm) {
        Long shipmentId = shipment.getId();
        var sourceCity = shipment.getSourceCity();
        var destCity = shipment.getDestinationCity();
        double weight = shipment.getWeight();

        if (sourceCity.getId().equals(destCity.getId())) {
            throw new BadRequestException("Source and destination cities must be different");
        }

        // Load graph once — all algorithms and objectives share this instance
        TransportGraph graph = graphLoader.loadGraph(weight);

        // Resolve the objective function
        ObjectiveFunction objective = ObjectiveType.resolve(optimizationType);

        // For BALANCED, set normalization bounds from the graph
        if (objective instanceof BalancedObjective balanced) {
            setBalancedNormalization(balanced, graph);
        }

        // Run pathfinding
        PathResult pathResult = algorithm.findPath(graph, sourceCity.getId(),
                destCity.getId(), objective, weight);

        if (!pathResult.hasPath()) {
            // Restore original exception type for backward compatibility
            throw new com.optimizer.backend.Exception.ResourceNotFoundException(
                    "No valid path found between source and destination");
        }

        // Apply transfer time to totalTime
        double transferTime = transferTimeCalculator.totalTransferTime(pathResult.edges());
        double totalTimeWithTransfer = pathResult.totalTime() + transferTime;

        // Build the optimization result — using PathResult as single source of truth
        String pathJson = toPathJson(pathResult, weight, graph);
        OptimizationResult optimizationResult = optimizationResultRepository.findByShipmentId(shipmentId)
                .orElseGet(OptimizationResult::new);
        optimizationResult.setShipment(shipment);
        optimizationResult.setTotalCost(pathResult.totalCost());
        optimizationResult.setTotalTime(totalTimeWithTransfer);
        optimizationResult.setTotalDistance(pathResult.totalDistance());
        optimizationResult.setTotalCarbon(pathResult.totalCarbon());
        optimizationResult.setOptimizedAt(LocalDateTime.now());
        optimizationResult.setPath(pathJson);

        OptimizationResponseDTO response = toResponse(shipmentId, optimizationType, pathResult, totalTimeWithTransfer, graph);

        // Step 6: Attempt ML ETA prediction (non-blocking)
        try {
            Optional<EtaPredictionResponse> etaResponse = etaPredictionService.predictEta(pathResult, weight, graph);
            if (etaResponse.isPresent()) {
                response.setPredictedEtaHours(etaResponse.get().predictedEtaHours());
                response.setEtaPredictionAvailable(true);
            } else {
                response.setPredictedEtaHours(null);
                response.setEtaPredictionAvailable(false);
                log.info("ETA prediction unavailable for shipment {}", shipmentId);
            }
        } catch (Exception e) {
            log.warn("ETA prediction failed for shipment {}: {}", shipmentId, e.getMessage());
            response.setPredictedEtaHours(null);
            response.setEtaPredictionAvailable(false);
        }

        // Persist the prediction with the result: without it, a page reload calls
        // getByShipmentId() and would report the ML service as offline even when
        // the prediction succeeded above.
        optimizationResult.setPredictedEtaHours(response.getPredictedEtaHours());
        optimizationResultRepository.save(optimizationResult);

        return response;
    }

    @Transactional(readOnly = true)
    public OptimizationResponseDTO getByShipmentId(Long shipmentId) {
        OptimizationResult optimizationResult = optimizationResultRepository.findByShipmentId(shipmentId)
                .orElseThrow(() -> new com.optimizer.backend.Exception.ResourceNotFoundException(
                        "Optimization result not found for shipment id: " + shipmentId));

        List<String> cityNames = extractCityNames(optimizationResult.getPath());
        List<OptimizationResponseDTO.RouteStepDTO> routeSteps = extractRouteSteps(optimizationResult.getPath());

        return OptimizationResponseDTO.builder()
                .shipmentId(shipmentId)
                .optimizationType(null)
                .totalCost(optimizationResult.getTotalCost())
                .totalTime(optimizationResult.getTotalTime())
                .totalDistance(optimizationResult.getTotalDistance() != null ? optimizationResult.getTotalDistance() : 0.0)
                .totalCarbon(optimizationResult.getTotalCarbon() != null ? optimizationResult.getTotalCarbon() : 0.0)
                .cities(cityNames)
                .routes(routeSteps)
                .predictedEtaHours(optimizationResult.getPredictedEtaHours())
                .etaPredictionAvailable(optimizationResult.getPredictedEtaHours() != null)
                .build();
    }

    /**
     * Compare A* and Dijkstra for a given shipment and objective.
     */
    @Transactional
    public AlgorithmComparator.ComparisonResult compareAlgorithms(
            Shipment shipment, OptimizationType optimizationType) {
        double weight = shipment.getWeight();

        TransportGraph graph = graphLoader.loadGraph(weight);
        ObjectiveFunction objective = ObjectiveType.resolve(optimizationType);

        if (objective instanceof BalancedObjective balanced) {
            setBalancedNormalization(balanced, graph);
        }

        AlgorithmComparator comparator = new AlgorithmComparator();
        return comparator.compare(graph,
                shipment.getSourceCity().getId(),
                shipment.getDestinationCity().getId(),
                objective, weight);
    }

    // ── Private helpers ──

    private void setBalancedNormalization(BalancedObjective balanced, TransportGraph graph) {
        double maxCost = 0, maxTime = 0, maxCarbon = 0;
        for (var edges : graph.adjacency().values()) {
            for (GraphEdge e : edges) {
                maxCost = Math.max(maxCost, e.cost());
                maxTime = Math.max(maxTime, e.time());
                maxCarbon = Math.max(maxCarbon, e.carbon());
            }
        }
        balanced.setNormalizationBounds(maxCost, maxTime, maxCarbon);
    }

    private String toPathJson(PathResult pathResult, double weight, TransportGraph graph) {
        // Build cities part from edges
        List<String> cityNames = new ArrayList<>();
        if (!pathResult.edges().isEmpty()) {
            cityNames.add(graph.getCity(pathResult.edges().get(0).sourceId()).getName());
            for (GraphEdge edge : pathResult.edges()) {
                cityNames.add(graph.getCity(edge.destinationId()).getName());
            }
        }

        String citiesPart = cityNames.stream()
                .map(this::encodeToken)
                .collect(Collectors.joining(","));

        String routesPart = pathResult.edges().stream()
                .map(edge -> String.join("|",
                        encodeToken(graph.getCity(edge.sourceId()).getName()),
                        encodeToken(graph.getCity(edge.destinationId()).getName()),
                        encodeToken(edge.modeType().name()),
                        Double.toString(edge.distance()),
                        Double.toString(edge.cost()),
                        Double.toString(edge.time()),
                        Double.toString(edge.carbon())))
                .collect(Collectors.joining(","));

        return "C:" + citiesPart + ";R:" + routesPart;
    }

    private OptimizationResponseDTO toResponse(Long shipmentId, OptimizationType optimizationType,
                                               PathResult pathResult, double totalTimeWithTransfer,
                                               TransportGraph graph) {
        List<String> cityNames = new ArrayList<>();
        if (!pathResult.edges().isEmpty()) {
            cityNames.add(graph.getCity(pathResult.edges().get(0).sourceId()).getName());
            for (GraphEdge edge : pathResult.edges()) {
                cityNames.add(graph.getCity(edge.destinationId()).getName());
            }
        }

        List<OptimizationResponseDTO.RouteStepDTO> routeSteps = pathResult.edges().stream()
                .map(edge -> OptimizationResponseDTO.RouteStepDTO.builder()
                        .sourceCity(graph.getCity(edge.sourceId()).getName())
                        .destinationCity(graph.getCity(edge.destinationId()).getName())
                        .transportMode(edge.modeType().name())
                        .distance(edge.distance())
                        .cost(edge.cost())
                        .time(edge.time())
                        .carbon(edge.carbon())
                        .build())
                .toList();

        return OptimizationResponseDTO.builder()
                .shipmentId(shipmentId)
                .optimizationType(optimizationType)
                .totalCost(pathResult.totalCost())
                .totalTime(totalTimeWithTransfer)
                .totalDistance(pathResult.totalDistance())
                .totalCarbon(pathResult.totalCarbon())
                .cities(cityNames)
                .routes(routeSteps)
                .build();
    }

    private List<String> extractCityNames(String pathJson) {
        if (pathJson == null || pathJson.isBlank() || !pathJson.startsWith("C:")) {
            return Collections.emptyList();
        }
        String[] sections = pathJson.split(";R:", 2);
        String citiesSection = sections[0].substring(2);
        if (citiesSection.isBlank()) {
            return Collections.emptyList();
        }
        List<String> cities = new ArrayList<>();
        for (String token : citiesSection.split(",")) {
            if (!token.isBlank()) {
                cities.add(decodeToken(token));
            }
        }
        return cities;
    }

    private List<OptimizationResponseDTO.RouteStepDTO> extractRouteSteps(String pathJson) {
        if (pathJson == null || pathJson.isBlank()) {
            return Collections.emptyList();
        }
        String[] sections = pathJson.split(";R:", 2);
        if (sections.length < 2 || sections[1].isBlank()) {
            return Collections.emptyList();
        }
        List<OptimizationResponseDTO.RouteStepDTO> steps = new ArrayList<>();
        for (String routeToken : sections[1].split(",")) {
            if (routeToken.isBlank()) continue;
            String[] fields = routeToken.split("\\|", -1);
            if (fields.length < 6) continue;
            steps.add(OptimizationResponseDTO.RouteStepDTO.builder()
                    .sourceCity(decodeToken(fields[0]))
                    .destinationCity(decodeToken(fields[1]))
                    .transportMode(decodeToken(fields[2]))
                    .distance(asDouble(fields[3]))
                    .cost(asDouble(fields[4]))
                    .time(asDouble(fields[5]))
                    .carbon(fields.length > 6 ? asDouble(fields[6]) : 0.0)
                    .build());
        }
        return steps;
    }

    private double asDouble(Object value) {
        if (value instanceof Number number) return number.doubleValue();
        if (value instanceof String s) {
            try { return Double.parseDouble(s); } catch (NumberFormatException e) { return 0.0; }
        }
        return 0.0;
    }

    private String encodeToken(String value) {
        return Base64.getUrlEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private String decodeToken(String token) {
        try {
            return new String(Base64.getUrlDecoder().decode(token), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException ex) {
            return "";
        }
    }
}

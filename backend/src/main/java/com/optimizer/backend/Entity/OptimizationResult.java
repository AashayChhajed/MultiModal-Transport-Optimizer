package com.optimizer.backend.Entity;

import jakarta.persistence.*;
import lombok.*;

import java.time.LocalDateTime;

@Entity
@Table(name = "optimization_result")
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class OptimizationResult {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @OneToOne(optional = false)
    @JoinColumn(name = "shipment_id")
    private Shipment shipment;

    @Column(nullable = false)
    private Double totalCost;

    @Column(nullable = false)
    private Double totalTime;

    private Double totalDistance;

    private Double totalCarbon;

    private LocalDateTime optimizedAt;

    /**
     * ETA predicted by the ML service when this result was computed.
     * Null when the ML service was unavailable at optimize time, so the
     * stored result can distinguish "not predicted" from "service offline".
     */
    private Double predictedEtaHours;

    @Lob
    @Column(columnDefinition = "TEXT", nullable = false)
    private String path;
}

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// MARK: - Shared

// Utility functions
float2x2 rotate2d(float angle) {
    return float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
}

half4 applyKawaseBlur(SwiftUI::Layer layer, float2 p, float2 uSize, float blurRadius) {
    if (blurRadius < 0.001) {
        return layer.sample(p);
    }
    
    half4 color = half4(0.0);
    float totalWeight = 0.0;
    float2 texelSize = 1.0 / uSize;
    float2 uv = p / uSize;
    
    float offset = blurRadius;
    
    float2 offsets1[4] = { float2(-offset, -offset), float2(offset, -offset), float2(-offset, offset), float2(offset, offset) };
    for (int i = 0; i < 4; i++) {
        float2 sampleUV = uv + offsets1[i] * texelSize;
        color += layer.sample(sampleUV * uSize);
        totalWeight += 1.0;
    }
    
    float offset2 = offset * 1.5;
    float2 offsets2[4] = { float2(0.0, -offset2), float2(0.0, offset2), float2(-offset2, 0.0), float2(offset2, 0.0) };
    for (int i = 0; i < 4; i++) {
        float2 sampleUV = uv + offsets2[i] * texelSize;
        color += layer.sample(sampleUV * uSize) * 0.8;
        totalWeight += 0.8;
    }
    
    float offset3 = offset * 0.7;
    float2 offsets3[4] = { float2(-offset3, 0.0), float2(offset3, 0.0), float2(0.0, -offset3), float2(0.0, offset3) };
    for (int i = 0; i < 4; i++) {
        float2 sampleUV = uv + offsets3[i] * texelSize;
        color += layer.sample(sampleUV * uSize) * 0.6;
        totalWeight += 0.6;
    }
    
    color += layer.sample(p) * 2.0;
    totalWeight += 2.0;
    
    return totalWeight > 0.0 ? color / totalWeight : layer.sample(p);
}

// Calculate height/depth of the liquid surface
float getHeight(float sd, float thickness) {
    if (sd >= 0.0 || thickness <= 0.0) {
        return 0.0;
    }
    if (sd < -thickness) {
        return thickness;
    }
    
    float x = thickness + sd;
    return sqrt(max(0.0, thickness * thickness - x * x));
}

// Calculate lighting effects based on displacement data
float3 calculateLighting(float3 normal, float height, float2 refractionDisplacement, float thickness, float lightAngle, float lightIntensity, float ambientStrength) {
    // Basic shape mask
    float normalizedHeight = thickness > 0.0 ? height / thickness : 0.0;
    float shape = smoothstep(0.0, 0.9, 1.0 - normalizedHeight);

    // If we're outside the shape, no lighting.
    if (shape < 0.01) {
        return float3(0.0);
    }
    
    float3 viewDir = float3(0.0, 0.0, 1.0);

    // --- Rim lighting (Fresnel) ---
    // This creates a constant, soft outline.
    float fresnel = pow(1.0 - max(0.0, dot(normal, viewDir)), 3.0);
    float3 rimLight = float3(fresnel * ambientStrength * 0.5);

    // --- Light-dependent effects ---
    float3 lightDir = normalize(float3(cos(lightAngle), sin(lightAngle), -0.7));
    float3 oppositeLightDir = normalize(float3(-lightDir.xy, lightDir.z));

    // Common vectors needed for both light sources
    float3 halfwayDir1 = normalize(lightDir + viewDir);
    float specDot1 = max(0.0, dot(normal, halfwayDir1));
    float3 halfwayDir2 = normalize(oppositeLightDir + viewDir);
    float specDot2 = max(0.0, dot(normal, halfwayDir2));

    // 1. Sharp surface glint (pure white)
    float glintExponent = mix(120.0, 200.0, smoothstep(5.0, 25.0, thickness));
    float sharpFactor = pow(specDot1, glintExponent) + 0.4 * pow(specDot2, glintExponent);

    // Pure white glint without environment tinting
    float3 sharpGlint = float3(sharpFactor) * lightIntensity * 2.5;

    // 2. Soft internal bleed, for a subtle "glow"
    float softFactor = pow(specDot1, 20.0) + 0.5 * pow(specDot2, 20.0);
    float3 softBleed = float3(softFactor) * lightIntensity * 0.4;
    
    // Combine lighting components
    float3 lighting = rimLight + sharpGlint + softBleed;

    // Final combination
    return lighting * shape;
}

// Calculate refraction with chromatic aberration and optional blur
half4 calculateRefraction(
    float2 p,
    float3 normal,
    float height,
    float thickness,
    float refractiveIndex,
    float chromaticAberration,
    float2 uSize,
    SwiftUI::Layer layer,
    float blurRadius,
    thread float2 &refractionDisplacement
) {
    float baseHeight = thickness * 8.0;
    float3 incident = float3(0.0, 0.0, -1.0);
    
    half4 refractColor;

    // To simulate a prism, we calculate refraction separately for each color channel
    // by slightly varying the refractive index.
    if (chromaticAberration > 0.001) {
        float iorR = refractiveIndex - chromaticAberration * 0.04; // Less deviation for red
        float iorG = refractiveIndex;
        float iorB = refractiveIndex + chromaticAberration * 0.08; // More deviation for blue

        // Red channel
        float3 refractVecR = refract(incident, normal, 1.0 / iorR);
        float refractLengthR = (height + baseHeight) / max(0.001, abs(refractVecR.z));
        float2 refractedUVR = p + (refractVecR.xy * refractLengthR);
        float red = applyKawaseBlur(layer, refractedUVR, uSize, blurRadius).r;

        // Green channel (we'll use this for the main displacement and alpha)
        float3 refractVecG = refract(incident, normal, 1.0 / iorG);
        float refractLengthG = (height + baseHeight) / max(0.001, abs(refractVecG.z));
        refractionDisplacement = refractVecG.xy * refractLengthG;
        float2 refractedUVG = p + refractionDisplacement;
        half4 greenSample = applyKawaseBlur(layer, refractedUVG, uSize, blurRadius);
        float green = greenSample.g;
        float bgAlpha = greenSample.a;

        // Blue channel
        float3 refractVecB = refract(incident, normal, 1.0 / iorB);
        float refractLengthB = (height + baseHeight) / max(0.001, abs(refractVecB.z));
        float2 refractedUVB = p + (refractVecB.xy * refractLengthB);
        float blue = applyKawaseBlur(layer, refractedUVB, uSize, blurRadius).b;
        
        refractColor = half4(red, green, blue, bgAlpha);
    } else {
        // Default path for no chromatic aberration
        float3 refractVec = refract(incident, normal, 1.0 / refractiveIndex);
        float refractLength = (height + baseHeight) / max(0.001, abs(refractVec.z));
        refractionDisplacement = refractVec.xy * refractLength;
        float2 refractedUV = p + refractionDisplacement;
        refractColor = applyKawaseBlur(layer, refractedUV, uSize, blurRadius);
    }
    
    return refractColor;
}

// Apply glass color tinting to the liquid color
half4 applyGlassColor(half4 liquidColor, half4 glassColor) {
    half4 finalColor = liquidColor;
    
    if (glassColor.a > 0.0) {
        float glassLuminance = dot(glassColor.rgb, half3(0.299, 0.587, 0.114));
        
        if (glassLuminance < 0.5) {
            half3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
            finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
        } else {
            half3 invLiquid = half3(1.0) - liquidColor.rgb;
            half3 invGlass = half3(1.0) - glassColor.rgb;
            half3 screened = half3(1.0) - (invLiquid * invGlass);
            finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
        }
        
        finalColor.a = liquidColor.a;
    }
    
    return finalColor;
}

// Complete liquid glass rendering pipeline
half4 renderLiquidGlass(
    float2 p,
    float2 uSize,
    float sd,
    float thickness,
    float refractiveIndex,
    float chromaticAberration,
    half4 glassColor,
    float lightAngle,
    float lightIntensity,
    float ambientStrength,
    SwiftUI::Layer layer,
    float3 normal,
    float foregroundAlpha,
    float blurRadius,
    float isRefractionEnabled,
    float isLightingEnabled,
    float isGlassColorEnabled,
    float isBlurEnabled
) {
    // If we're completely outside the glass area (with smooth transition)
    if (foregroundAlpha < 0.001) {
        return layer.sample(p);
    }
    
    // If thickness is effectively zero, behave like a simple blur
    if (thickness < 0.01) {
        return layer.sample(p);
    }
    
    float height = getHeight(sd, thickness);
    
    // Calculate refraction & chromatic aberration with blur applied to the sampling
    float2 refractionDisplacement = float2(0.0);
    half4 refractColor;
    if (isRefractionEnabled > 0.5) {
        refractColor = calculateRefraction(p, normal, height, thickness, refractiveIndex, chromaticAberration, uSize, layer, isBlurEnabled > 0.5 ? blurRadius : 0.0, refractionDisplacement);
    } else {
        // If refraction is disabled, still apply blur if it's enabled.
        if (isBlurEnabled > 0.5) {
            refractColor = applyKawaseBlur(layer, p, uSize, blurRadius);
        } else {
            refractColor = layer.sample(p);
        }
    }
    
    // Mix refraction and reflection based on normal.z
    half4 liquidColor = refractColor;
    
    // Calculate lighting effects
    float3 lighting = isLightingEnabled > 0.5 ? calculateLighting(normal, height, refractionDisplacement, thickness, lightAngle, lightIntensity, ambientStrength) : float3(0.0);
    
    // Apply realistic glass color influence
    half4 finalColor = isGlassColorEnabled > 0.5 ? applyGlassColor(liquidColor, glassColor) : liquidColor;
    
    // Add lighting effects to final color
    finalColor.rgb += half3(lighting);
    
    // Use alpha for smooth transition at boundaries
    half4 backgroundColor = layer.sample(p);
    return mix(backgroundColor, finalColor, foregroundAlpha);
}

// MARK: - SDF

float sdfRRect( float2 p, float2 b, float r ) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);
    float2 q = abs(p)-b+r;
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r;
}

float sdfRect(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdfSquircle(float2 p, float2 b, float r, float n) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);

    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + pow(
        pow(max(q.x, 0.0), n) + pow(max(q.y, 0.0), n),
        1.0 / n
    ) - r;
}

float sdfEllipse(float2 p, float2 r) {
    r = max(r, 1e-4);
    float k1 = length(p / r);
    float k2 = length(p / (r * r));
    return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

float smoothUnion(float d1, float d2, float k) {
    if (k <= 0.0) {
        return min(d1, d2);
    }
    float e = max(k - abs(d1 - d2), 0.0);
    return min(d1, d2) - e * e * 0.25 / k;
}

float getShapeSDF(float type, float2 p, float2 center, float2 size, float r) {
    if (type == 1.0) { // squircle
        return sdfSquircle(p - center, size / 2.0, r, 2.0);
    }
    if (type == 2.0) { // ellipse
        return sdfEllipse(p - center, size / 2.0);
    }
    if (type == 3.0) { // rounded rectangle
        return sdfRRect(p - center, size / 2.0, r);
    }
    return 1e9; // none
}

// MARK: - Main

[[stitchable]] half4 liquidGlass(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float chromaticAberration,
    half4 glassColor,
    float lightAngle,
    float lightIntensity,
    float ambientStrength,
    float thickness,
    float refractiveIndex,
    float shape1Type,
    float2 shape1Center,
    float2 shape1Size,
    float shape1CornerRadius,
    float shape2Type,
    float2 shape2Center,
    float2 shape2Size,
    float shape2CornerRadius,
    float shape3Type,
    float2 shape3Center,
    float2 shape3Size,
    float shape3CornerRadius,
    float blend,
    float blurRadius,
    float isSmoothUnionEnabled,
    float isRefractionEnabled,
    float isLightingEnabled,
    float isGlassColorEnabled,
    float isBlurEnabled
) {
    // Scene SDF
    float d1 = getShapeSDF(shape1Type, position, shape1Center, shape1Size, shape1CornerRadius);
    float d2 = getShapeSDF(shape2Type, position, shape2Center, shape2Size, shape2CornerRadius);
    float d3 = getShapeSDF(shape3Type, position, shape3Center, shape3Size, shape3CornerRadius);
    float sd = (isSmoothUnionEnabled > 0.5) ? smoothUnion(smoothUnion(d1, d2, blend), d3, blend) : min(min(d1, d2), d3);

    // Normal
    float dx = dfdx(sd);
    float dy = dfdy(sd);
    float n_cos = max(thickness + sd, 0.0) / thickness;
    float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
    float3 normal = normalize(float3(dx * n_cos, dy * n_cos, n_sin));

    float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);

    if (foregroundAlpha < 0.01) {
        return layer.sample(position);
    }
    
    return renderLiquidGlass(
        position,
        size,
        sd,
        thickness,
        refractiveIndex,
        chromaticAberration,
        glassColor,
        lightAngle,
        lightIntensity,
        ambientStrength,
        layer,
        normal,
        foregroundAlpha,
        blurRadius,
        isRefractionEnabled,
        isLightingEnabled,
        isGlassColorEnabled,
        isBlurEnabled
    );
}

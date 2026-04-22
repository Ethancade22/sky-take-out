package com.sky.properties;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "sky.local-upload")
@Data
public class LocalStorageProperties {

    /**
     * 本地文件存储目录
     */
    private String basePath;

    /**
     * 文件对外访问路径前缀
     */
    private String accessPath = "/uploads/";

    public String getAccessPath() {
        if (accessPath == null || accessPath.trim().isEmpty()) {
            return "/uploads/";
        }

        String normalizedAccessPath = accessPath;
        if (!normalizedAccessPath.startsWith("/")) {
            normalizedAccessPath = "/" + normalizedAccessPath;
        }
        if (!normalizedAccessPath.endsWith("/")) {
            normalizedAccessPath = normalizedAccessPath + "/";
        }
        return normalizedAccessPath;
    }
}

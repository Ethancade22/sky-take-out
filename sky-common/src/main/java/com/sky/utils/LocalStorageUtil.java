package com.sky.utils;

import com.sky.properties.LocalStorageProperties;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;

@Component
public class LocalStorageUtil {

    private final Path storageDirectory;

    public LocalStorageUtil(LocalStorageProperties localStorageProperties) {
        this.storageDirectory = Paths.get(localStorageProperties.getBasePath())
                .toAbsolutePath()
                .normalize();
    }

    /**
     * 将文件写入本地磁盘
     *
     * @param bytes 文件字节数组
     * @param objectName 保存后的文件名
     * @return 保存后的文件名
     */
    public String upload(byte[] bytes, String objectName) throws IOException {
        Files.createDirectories(storageDirectory);

        Path targetFile = storageDirectory.resolve(objectName).normalize();
        if (!targetFile.startsWith(storageDirectory)) {
            throw new IOException("Invalid file path");
        }

        Files.write(targetFile, bytes, StandardOpenOption.CREATE_NEW);
        return targetFile.getFileName().toString();
    }
}

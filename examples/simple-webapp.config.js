#!/usr/bin/env node

/**
 * 간단한 웹 앱 모니터링 설정 예제
 * 하나의 Node.js 웹 서버를 모니터링
 */

const path = require('path');

// 프로젝트 루트 디렉토리 (여기를 수정하세요!)
const PROJECT_ROOT = '/home/nmsglobal/my-web-project';
const SERVICE_MONITOR_ROOT = path.dirname(__dirname);

module.exports = {
  // 모니터링 설정
  monitoring: {
    interval: 60000,                    // 60초마다 체크
    consecutiveFailureThreshold: 3,     // 3번 연속 실패시 재시작
    maxRestartAttempts: 5,              // 최대 5번 재시작 시도
    restartDelay: 4000,                 // 재시작 간격 4초
  },

  // 로그 설정
  logging: {
    level: 'INFO',                      // 로그 레벨
    logDir: path.join(PROJECT_ROOT, 'logs'),
    maxLogSizeMB: 50,                   // 50MB 초과시 로테이션
    retentionDays: 30,                  // 30일 보관
  },

  // 서비스 정의 (이 부분이 핵심!)
  services: [
    {
      name: 'my-webapp',                // 서비스 이름
      type: 'nodejs',                   // 서비스 타입
      port: 3000,                       // 포트 번호
      healthUrl: 'http://localhost:3000/health', // 헬스체크 URL
      
      // PM2 설정
      pm2Config: {
        script: 'npm',                  // 실행할 명령
        args: 'start',                  // 명령 인자
        cwd: PROJECT_ROOT,              // 작업 디렉토리
        instances: 1,                   // 인스턴스 수
        exec_mode: 'cluster',           // 실행 모드
        max_memory_restart: '512M',     // 메모리 제한
        
        // 환경 변수
        env: {
          NODE_ENV: 'production',
          PORT: 3000,
        },
        
        // 로그 파일
        out_file: path.join(PROJECT_ROOT, 'logs', 'webapp-out.log'),
        error_file: path.join(PROJECT_ROOT, 'logs', 'webapp-error.log'),
        merge_logs: true,
      },
      
      // 헬스체크 설정
      healthCheck: {
        enabled: true,                  // 헬스체크 활성화
        method: 'GET',                  // HTTP 메소드
        timeout: 10000,                 // 타임아웃 (ms)
        expectedStatus: 200,            // 예상 상태코드
      },
      
      // 자동 재시작 설정
      autoRestart: {
        enabled: true,
        onPortDown: true,               // 포트 다운시 재시작
        onHealthCheckFail: true,        // 헬스체크 실패시 재시작
        onMemoryLimit: true,            // 메모리 초과시 재시작
        onCrash: true,                  // 크래시시 재시작
      },
    }
  ],
};
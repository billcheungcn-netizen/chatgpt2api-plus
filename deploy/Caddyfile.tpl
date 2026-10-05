# 由 deploy.sh 渲染到 runtime/caddy/Caddyfile
{
__GLOBAL_EMAIL__
}

__DOMAIN__ {
	encode gzip
	request_body {
		max_size 100MB
	}
	reverse_proxy app:80 {
		# SSE / 流式输出立即下发
		flush_interval -1
		transport http {
			read_timeout 600s
			write_timeout 600s
		}
	}
}

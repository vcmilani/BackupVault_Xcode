# BackupVault — macOS Client

Cliente macOS nativo em SwiftUI para o servidor [backup_files](https://github.com/vcmilani/backup_files).

---

## Requisitos

| Item | Versão mínima |
|------|--------------|
| macOS | 14.0 (Sonoma) |
| Xcode | 15.0 |
| Swift | 5.9 |
| Servidor | backup_files v2.1+ |

---

## Estrutura do projeto

```
BackupVault_Xcode/
├── BackupVault.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/
│       └── BackupVault.xcscheme
└── BackupVault/
    ├── BackupVaultApp.swift       # Entry point · MenuBarExtra · Settings scene
    ├── Models.swift               # Modelos do contrato v2.1 (BackupSummary, VersionInfo, FileInfo…)
    ├── APIService.swift           # Camada de rede — endpoints do FastAPI
    ├── ConfigStore.swift          # Persistência local de perfis (UserDefaults)
    ├── ContentView.swift          # Janela principal · sidebar fixa
    ├── DashboardView.swift        # Estatísticas globais e explicação do sistema
    ├── BackupsView.swift          # Navegador backups → versões → arquivos
    ├── BackupConfigsView.swift    # CRUD de perfis · ExcludesEditor isolado
    ├── BackupRunner.swift         # Engine de execução · upload binário com headers
    ├── BackupRunnerView.swift     # Sheet de execução individual com log e cancel
    ├── BackupQueue.swift          # Engine de fila (vários perfis em sequência)
    ├── BackupQueueView.swift      # Sheet de fila com seleção e progresso
    ├── CleanupView.swift          # Limpeza de versões antigas no servidor
    ├── SettingsView.swift         # URL do servidor · API Key · teste de conexão
    ├── MenuBarView.swift          # Painel compacto da barra de menu
    ├── PlaceholderView.swift      # Substituto de ContentUnavailableView
    ├── Info.plist                 # ATS · NSLocalNetworkUsageDescription
    ├── BackupVault.entitlements   # Network client · file access
    ├── AppIcon.svg                # Ícone vetorial alta resolução
    └── Assets.xcassets/
        └── AppIcon.appiconset/
```

---

## Configuração antes de rodar

1. Abra `BackupVault.xcodeproj` no Xcode
2. Em **Signing & Capabilities**, selecione seu Team
3. (Opcional) Troque o `PRODUCT_BUNDLE_IDENTIFIER` em Build Settings
4. Em **Assets.xcassets → AppIcon**, ative *Single Size* e arraste um PNG 1024×1024 gerado a partir do `AppIcon.svg`
5. ⌘R para rodar

---

## Funcionalidades

### Dashboard
- Cards com totais: backups, versões, arquivos e storage
- Lista de backups ativos com tamanho e última versão
- Painel explicativo: deduplicação SHA-256, versionamento, isolamento por label, arquivos deletados
- Banner de alerta quando o servidor está inacessível

### Backups (navegador do servidor)
- Layout em 3 painéis com `HStack` puro (sem espaços fantasma)
- Lista de backups → versões → arquivos
- Filtro por nome de backup e nome de arquivo
- Tabela de arquivos com SHA-256, status (active/deleted) e tamanho
- Filtro `include_deleted=true` para ver arquivos removidos do cliente
- Excluir versão individual (menu de contexto)

### Meus Backups (perfis locais)
- Cria e gerencia múltiplos perfis localmente
- Cada perfil: nome, label, pasta, servidor (override), workers, prefixo, exclusões
- Seletor nativo de pasta (`NSOpenPanel`)
- Editor em 3 abas com `Picker` segmentado
- `ExcludesEditor` isolado em view própria com `@Binding`
- Executar backup individual (sheet com progresso e log)
- Executar fila com seleção de múltiplos perfis
- Excluir backup do servidor (menu de contexto)
- Preview do comando Python equivalente

### Fila de Execução
- Lista todos os perfis ativos com label e pasta definidos
- Pré-seleciona todos automaticamente
- Toda a linha clicável para selecionar/desselecionar
- Botão "Selecionar Todos" para reset
- Contador dinâmico no botão "Iniciar Fila (N)"
- Execução sequencial com progresso geral + por item
- Item atual destacado com barra de progresso e nome do arquivo
- Botão "Parar Fila" cancela tudo a partir do próximo arquivo
- Botão "Executar Novamente" após conclusão

### Limpeza
- Modo: todos os backups ou label específico
- Stepper para definir versões a manter (padrão: 5)
- Pré-visualização por label antes de executar
- Confirmação obrigatória (operação irreversível)
- Resultado detalhado: versões removidas e arquivos liberados

### Barra de Menu (`MenuBarExtra`)
- Ícone com indicador visual de conexão
- Painel compacto: status, mini-stats, 5 backups recentes
- Atalho rápido para janela principal e Ajustes

### Ajustes
- URL do servidor e API Key com persistência em `UserDefaults`
- Teste de conexão com feedback inline
- Migração automática do bundle ID antigo
- Detecção amigável do erro -1009 (rede local bloqueada)
- Links para Swagger UI, Dashboard Web e GitHub

---

## Integração com o servidor (contrato v2.1)

### Endpoints utilizados

| Método | Endpoint | Uso |
|--------|----------|-----|
| `GET` | `/health` | Verificar conexão |
| `GET` | `/backups` | Listar backups com `version_count`, `file_count`, `total_size_bytes` |
| `GET` | `/backups/{label}/versions` | Listar versões com `file_count`, `deleted_count`, `total_size_bytes` |
| `GET` | `/files?backup_label=&version_key=&include_deleted=true` | Listar arquivos da versão |
| `POST` | `/backups` | Criar backup com `label` e `client_name` |
| `POST` | `/backups/{label}/versions` | Criar versão com `version_key` ISO 8601 |
| `POST` | `/check` | Verificar se conteúdo já existe (`needs_upload`, `content_exists`) |
| `POST` | `/upload` | Enviar arquivo (binário) ou registrar (header `X-Content-Sha256`) |
| `POST` | `/sync` | Marcar arquivos ausentes como deletados (`existing_paths`) |
| `PATCH` | `/backups/{label}/versions/{key}` | Finalizar versão (`status: done` ou `failed`) |
| `POST` | `/backups/{label}/cleanup` | Remover versões antigas (`keep`) |
| `DELETE` | `/backups/{label}/versions/{key}` | Excluir versão |
| `DELETE` | `/backups/{label}` | Excluir backup completo do servidor |

### Upload — protocolo binário com headers

Quando `content_exists = false` (conteúdo novo):
```
POST /upload
Content-Type: application/octet-stream
X-Backup-Label:   meu-backup
X-Version-Key:    2026-04-26T15:30:00Z
X-Original-Path:  <path em base64>
X-Mtime:          1714145400.0

<bytes do arquivo>
```

Quando `content_exists = true` (conteúdo já no storage, só registrar):
```
POST /upload
X-Backup-Label:    meu-backup
X-Version-Key:     2026-04-26T15:30:00Z
X-Original-Path:   <path em base64>
X-Content-Sha256:  <hash>
X-Mtime:           1714145400.0
(sem body)
```

Autenticação via header `X-API-Key` quando configurado.

---

## Persistência local

| Dado | Chave UserDefaults |
|------|--------------------|
| URL do servidor | `serverURL` |
| API Key | `apiKey` |
| Perfis de backup | `backupProfiles_v1` |

Migração automática do bundle ID antigo (`com.backupvault.app` → `com.vcm.backupvault.app`) na primeira execução.

---

## Permissões macOS

O app declara no `Info.plist`:

- **`NSLocalNetworkUsageDescription`** — necessário no macOS 15+ para acessar a rede local
- **`NSAppTransportSecurity`** com `NSAllowsLocalNetworking` — permite HTTP em IPs locais
- **Hardened Runtime** ativo, sandbox desativado
- **`com.apple.security.network.client`** + **`files.user-selected.read-only`** nas entitlements

Na primeira tentativa de conexão, o macOS pedirá permissão de rede local — clique em **Permitir**.

---

## Servidor (referência rápida)

```bash
# Na Raspberry Pi
cd backup_files/server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export BACKUP_API_KEY="sua-chave"
export STORAGE_DIR="/mnt/hd-externo/backups"
export DB_PATH="/mnt/hd-externo/backup.db"

uvicorn main:app --host 0.0.0.0 --port 8000
```

Dashboard web: `http://<ip-da-pi>:8000/`  
Swagger UI:    `http://<ip-da-pi>:8000/docs`

---

## Resolução de problemas

| Sintoma | Causa | Solução |
|---------|-------|---------|
| Erro `-1009` | Permissão de rede local negada | Configurações → Privacidade → Rede Local → ativar BackupVault |
| `BadRequest` no upload | Servidor anterior à v2.1 | Atualizar o servidor para a v2.1+ |
| `connection refused` | Servidor offline | `systemctl status backup-server` na Pi |
| Dashboard mostra 0 storage | Campo `total_size_bytes` ausente | Atualizar o servidor para a v2.1+ |
| Sidebar some ao redimensionar | (corrigido) | Atualize para a versão atual com `columnVisibility: .constant(.all)` |
